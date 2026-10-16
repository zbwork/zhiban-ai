package wukongwh

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"strings"
)

// CallSignalAudit 是 CallSignalSink 写入 call_event 审计表的一行记录(F16 spec v0.6.4 §6.2.6 + §13a.7)。
//
// 不变量: CallSignalSink 唯一副作用 = 写一条 call_event(source='webhook', event_type='signal_<verb>')。
// **绝不**调用任何 CallService 状态推进方法。call_session.state 推进始终走
// /api/agent-bus/v1/calls/* HTTP + 权限闸口(spec §4.1.0)。
type CallSignalAudit struct {
	// EventType 形如 signal_invite / signal_accept / signal_reject / signal_cancel /
	// signal_end / signal_ringing / signal_unknown(未识别动词)。
	EventType string
	// Source 永远为 "webhook"。
	Source string
	// MessageID 是 WuKong 消息 ID(已通过 webhook 幂等), 便于追溯。
	MessageID string
	// FromUID 是发出信令的 WuKong UID (t_<tenant>_u_<account_uuid> 或 t_<tenant>_a_<agent_uuid>)。
	FromUID     string
	ChannelID   string
	ChannelType int
	// CallUUID 若 payload.data.call_uuid 解到, 透传; 解不到留空(由审计层兜底 NULL)。
	CallUUID string
	// RawPayload 是原始 1001 payload JSON (base64 解出来的字节), 便于排障。
	RawPayload []byte
	// OccurredAt 是 WuKong 上报的消息时间戳 (unix 秒); 解不到留 0。
	OccurredAt int64
}

// CallEventWriter 是 CallSignalSink 唯一允许的副作用接口。
//
// 仅写审计表; 任何状态推进方法(Invite/Answer/Reject/Cancel/Leave/...)都**不**应出现在此接口上,
// 这是 spec §6.2.6 安全闸门在编译期的固化方式。
type CallEventWriter interface {
	WriteCallEvent(ctx context.Context, audit CallSignalAudit) error
}

// CallSignalSink 实现 Sink, 仅消费 ContentType=1001 的事件。
// 由 MuxSink 路由到这里; 其它 contentType 走 MuxSink 的另一条分支(@Agent 链路)。
type CallSignalSink struct {
	writer CallEventWriter
}

// NewCallSignalSink 注入 audit writer。writer 可为 nil(MVP 期 BE-03/BE-04 未落地时)
// 此时 Sink 仍按 spec §6.2.6 解析 payload 但不写库, 不会 panic。
func NewCallSignalSink(writer CallEventWriter) *CallSignalSink {
	return &CallSignalSink{writer: writer}
}

// 已知的合法信令动词(F16 spec §6.2.6 + §4.6 SignalingTransport)。其它会落为 signal_unknown 审计。
var rtcSignalVerbs = map[string]struct{}{
	"invite":  {},
	"cancel":  {},
	"accept":  {},
	"reject":  {},
	"end":     {},
	"ringing": {},
}

func (s *CallSignalSink) OnMessage(ctx context.Context, ev Event) error {
	if s == nil {
		return nil
	}
	if ev.ContentType != WKRtcCallSignalContentType {
		// 防御: MuxSink 已经按 contentType 路由, 这里不该收到非 1001;
		// 如果配置错装, 直接 drop, 不报错。
		return nil
	}

	verb, callUUID, raw := parseRtcSignalEnvelope(ev.Blocks)
	eventType := "signal_unknown"
	if _, ok := rtcSignalVerbs[verb]; ok {
		eventType = "signal_" + verb
	}

	audit := CallSignalAudit{
		EventType:   eventType,
		Source:      "webhook",
		MessageID:   ev.MessageID,
		FromUID:     ev.FromUID,
		ChannelID:   ev.ChannelID,
		ChannelType: ev.ChannelType,
		CallUUID:    callUUID,
		RawPayload:  raw,
		OccurredAt:  ev.Timestamp,
	}

	if s.writer == nil {
		// MVP: writer 未装配(BE-03/BE-04 未落地)→ 静默放过, 不写库, 不报错。
		// 后续 BE-07 装配 writer 后, 自动开始落 call_event。
		return nil
	}
	return s.writer.WriteCallEvent(ctx, audit)
}

// parseRtcSignalEnvelope 从 webhook decodeWKMessage 注入的 envelope 里取回原始 payload。
// envelope 形态: blocks[0]["_rtc_signal_raw"] = base64(原始 payload JSON)
// 返回 (event 字段, data.call_uuid 字段, 原始 payload bytes)。任一缺失返回空字符串(verb 缺失 → signal_unknown)。
func parseRtcSignalEnvelope(blocks []map[string]any) (verb, callUUID string, raw []byte) {
	if len(blocks) == 0 {
		return "", "", nil
	}
	b64Raw, ok := blocks[0]["_rtc_signal_raw"].(string)
	if !ok || b64Raw == "" {
		return "", "", nil
	}
	dec, err := base64.StdEncoding.DecodeString(b64Raw)
	if err != nil || len(dec) == 0 {
		return "", "", nil
	}
	var p struct {
		Type  int             `json:"type"`
		Event string          `json:"event"`
		Data  json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(dec, &p); err != nil {
		return "", "", dec
	}
	verb = strings.ToLower(strings.TrimSpace(p.Event))

	if len(p.Data) > 0 {
		var d struct {
			CallUUID string `json:"call_uuid"`
		}
		_ = json.Unmarshal(p.Data, &d)
		callUUID = strings.TrimSpace(d.CallUUID)
	}
	return verb, callUUID, dec
}
