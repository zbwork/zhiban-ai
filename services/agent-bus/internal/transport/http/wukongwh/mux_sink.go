package wukongwh

import "context"

// MuxSink 按 Event.ContentType 把已通过 webhook pre-filter 的事件分发到对应下游 Sink。
//
// F16 spec v0.6.4 §6.2.6 D14 关键不变量:
//   - 1 / 110 → wukongAgentTrigger (现有 @Agent 触发链路)
//   - 1001    → CallSignalSink (F16 RTC 信令; 只写 call_event 审计, 不推 state)
//   - 其它    → drop (webhook pre-filter 已挡, 这里再做防御)
//
// 装配示例 (cmd/bus/main.go):
//
//	mux := wukongwh.NewMuxSink(map[int]wukongwh.Sink{
//	    wukongwh.WKTextContentType:          agentTriggerSink,
//	    wukongwh.WKMixedContentType:         agentTriggerSink,
//	    wukongwh.WKRtcCallSignalContentType: callSignalSink,
//	})
//	wukongIM.Webhook.Sink = mux
//
// MuxSink 自身实现 Sink 接口, 与原来直接挂 wukongAgentTrigger 的装配 wire-compatible。
type MuxSink struct {
	sinks map[int]Sink
}

// NewMuxSink 构造一个 MuxSink。允许某条 contentType 映射到 nil(no-op)便于灰度。
// 调用方对 sinks 的所有权传入后归 MuxSink, 不要再修改原 map。
func NewMuxSink(sinks map[int]Sink) *MuxSink {
	if sinks == nil {
		sinks = map[int]Sink{}
	}
	return &MuxSink{sinks: sinks}
}

// OnMessage 把事件分发到 sinks[ev.ContentType], 不在路由表的 type 直接 drop。
// Nil 接收者 / Nil 下游 / 未匹配 type 全部 no-op (return nil), 防止单点错误污染 webhook 200。
func (m *MuxSink) OnMessage(ctx context.Context, ev Event) error {
	if m == nil {
		return nil
	}
	target := m.sinks[ev.ContentType]
	if target == nil {
		return nil
	}
	return target.OnMessage(ctx, ev)
}
