// frame.go — OpenClaw Gateway v3 协议的请求/响应/广播帧解析。
//
// 协议参考: docs.openclaw.ai/gateway/protocol.md +
//
//	legacy ai-office internal/services/gatewaywsclient/client.go rawFrame。
//
// v3 实际下行帧形状:
//
//	{ "type": "res",   "id": "...", "ok": true,  "payload": {...} }      // 响应
//	{ "type": "res",   "id": "...", "ok": false, "error":   {...} }      // 失败响应
//	{ "type": "event", "event": "session.message", "payload": {...} }    // 广播事件
//	{ "type": "event", "event": "connect.challenge", "payload": {...} }  // 握手前
//
// 早期/老网关存在 type="resp" 写法, 两种都接受以求兼容; 个别老网关响应帧不带
// type 字段, 靠 id 识别 (兜底)。
package gatewayws

import "encoding/json"

// Request 一条业务 RPC 请求 (method + params)。
type Request struct {
	RequireSuccess bool // Gate the main request on an acknowledged pre-request.
	Method         string
	Params         interface{}
}

// Frame 是从 WS 上读到的一条已解析帧, 可能是:
//   - Reply : 对调用方此前发出请求的响应 (Reply=true, ReqID 标识)
//   - Event : 服务端主动推送的广播事件 (Reply=false, Event 是事件名)
type Frame struct {
	Reply   bool            // true=响应自家请求; false=服务端广播事件
	ReqID   string          // 当 Reply 时, 对应哪条请求的 ID
	Event   string          // 当 !Reply 时, 事件名 (如 "session.message")
	OK      bool            // 当 Reply 时, 业务是否成功
	Payload json.RawMessage // 业务负载 (响应或事件 data)
	Error   json.RawMessage // 当 Reply && !OK 时
	Raw     json.RawMessage // 原始帧 JSON, 便于调试 / 解析未识别字段
}

// wsRequestFrame 发往服务端的请求帧 (method=req)。
type wsRequestFrame struct {
	Type   string      `json:"type"`
	ID     string      `json:"id"`
	Method string      `json:"method"`
	Params interface{} `json:"params,omitempty"`
}

// rawFrame 用来嗅探服务端帧 —— type/event 字段决定它是 reply 还是 broadcast。
type rawFrame struct {
	Type    string          `json:"type"`
	Event   string          `json:"event,omitempty"`   // 仅 broadcast 才有
	ID      string          `json:"id,omitempty"`      // 仅 reply 才有 (对应 request.id)
	OK      bool            `json:"ok,omitempty"`      // 仅 reply
	Payload json.RawMessage `json:"payload,omitempty"` // reply / 广播都可能有
	Data    json.RawMessage `json:"data,omitempty"`    // 兜底: 少数广播帧把数据放 data
	Error   json.RawMessage `json:"error,omitempty"`
}

// parseFrame 把 bytes 解析为 Frame; 返回 (frame, ok=true) 表示能识别。
func parseFrame(b []byte) (Frame, bool) {
	var rf rawFrame
	if err := json.Unmarshal(b, &rf); err != nil {
		return Frame{}, false
	}
	f := Frame{Raw: append(json.RawMessage(nil), b...)}
	switch {
	case rf.Type == "res" || rf.Type == "resp":
		f.Reply = true
		f.ReqID = rf.ID
		f.OK = rf.OK
		f.Payload = rf.Payload
		f.Error = rf.Error
		return f, true
	case rf.Type == "event" || rf.Event != "":
		f.Reply = false
		f.Event = rf.Event
		if len(rf.Payload) > 0 {
			f.Payload = rf.Payload
		} else if len(rf.Data) > 0 {
			f.Payload = rf.Data
		}
		return f, true
	case rf.Type == "" && rf.ID != "" && rf.Event == "":
		// 兜底: 极个别老网关响应帧不带 type 字段, 靠 id 识别
		f.Reply = true
		f.ReqID = rf.ID
		f.OK = rf.OK
		f.Payload = rf.Payload
		f.Error = rf.Error
		return f, true
	}
	return Frame{}, false
}
