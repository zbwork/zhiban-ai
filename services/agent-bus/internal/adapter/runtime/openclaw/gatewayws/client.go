// Package gatewayws 是 OpenClaw Gateway 原生 WebSocket 协议 (v3) 的轻量客户端。
//
// 来源: 移植 legacy ai-office `internal/services/gatewaywsclient/client.go`,
// 与 ai-office v2026.4.29 OpenClaw 实测验过的实现一致 (Batch 2C plan §0)。
//
// 设计原则:
//
//  1. **每次调用一条短期 WS 连接** (per-call short-lived):
//     - Bus 是无状态后端、多实例横扩, 维持 per-runtime 长连接需要归属管理、
//     滚动重启重连风暴、连接池共享等一堆复杂度。
//     - 用户场景 RPC 频次低, 握手 50-200ms 相对一次聊天 30s+ 几乎不可见。
//     - 不做连接池, 每次 Call/CallStream 都打开 + 握手 + 关闭。
//
//  2. **协议感知, 事件透传**:
//     本包认识 connect.challenge / connect / req / res / event 等 v3 帧类型,
//     但不知道任何业务事件名 (session.message/cron.*)。后者由调用方按需解析。
//
//  3. **可单测、可 mock**:
//     上层业务测试通过对接真实本地 OpenClaw dev 容器或 stub 服务端验证流程,
//     本批 2C 仅写最小握手单测 (Probe), 真实 CallStream 联调留 Batch 2D 真聊天验。
//
// 与文档 (https://docs.openclaw.ai/gateway/protocol.md) 对应:
//   - Step 1: server pushes connect.challenge
//   - Step 2: client sends method=connect with role/scopes/auth + caps:[tool-events]
//   - Step 3: server replies hello-ok or rejects
//   - Step 4+: client sends method=<rpc>; server replies + may emit broadcast events
package gatewayws

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
)

var ErrRequiredRequestRejected = errors.New("gateway required request rejected")

// Endpoint 描述一个 OpenClaw Gateway 实例的连接信息。
// HTTPURL 形如 "http://<podIP>:18789"; 内部自动转 ws:// + /ws path。
type Endpoint struct {
	HTTPURL string
	Bearer  string
}

// Option 用于配置 Client 行为。
type Option func(*Client)

// Client 是 gateway WS 客户端。线程安全, 可在多个 goroutine 中并发调用。
type Client struct {
	scopes             []string
	clientID           string
	clientVersion      string
	clientPlatform     string
	clientMode         string
	handshakeTimeout   time.Duration
	defaultRPCTimeout  time.Duration
	defaultStreamLimit time.Duration
}

// New 构造一个 Client。默认 scope 为 operator.admin (覆盖 read/write/approvals)。
//
// **clientID 必须是 "openclaw-control-ui"**: OpenClaw v3 protocol 在 connect 请求里校验
// /client/id 是否在 allowed values 中, 写自定义名 (如 "agent-bus") 会被服务端返回
// `INVALID_REQUEST: at /client/id: must be equal to one of the allowed values`,
// 整个 connect 直接被拒。legacy ai-office 也是用这个 id 跑通的。
func New(opts ...Option) *Client {
	c := &Client{
		scopes:             []string{"operator.admin"},
		clientID:           "openclaw-control-ui", // OpenClaw v3 仅接受这一组 allowed values
		clientVersion:      "agent-bus",
		clientPlatform:     "server",
		clientMode:         "webchat",
		handshakeTimeout:   10 * time.Second,
		defaultRPCTimeout:  30 * time.Second,
		defaultStreamLimit: 15 * time.Minute,
	}
	for _, opt := range opts {
		opt(c)
	}
	return c
}

// WithScopes 覆盖默认 connect scopes (默认 ["operator.admin"])。
func WithScopes(scopes ...string) Option {
	return func(c *Client) { c.scopes = append([]string(nil), scopes...) }
}

// WithHandshakeTimeout 覆盖握手阶段超时。
func WithHandshakeTimeout(d time.Duration) Option {
	return func(c *Client) { c.handshakeTimeout = d }
}

// WithDefaultRPCTimeout 覆盖 Call 等待响应的默认超时。
func WithDefaultRPCTimeout(d time.Duration) Option {
	return func(c *Client) { c.defaultRPCTimeout = d }
}

// WithDefaultStreamLimit 覆盖 CallStream 整体生命周期上限。
func WithDefaultStreamLimit(d time.Duration) Option {
	return func(c *Client) { c.defaultStreamLimit = d }
}

// Probe 仅做一次「dial + connect 握手」探活: 拨一条 WS、跑完 v3 connect.challenge /
// connect / hello-ok 三步, 确认服务端真的能接 RPC 后立刻关闭连接。
//
// 用途: Bus 健康检查 (T2C.2 runtime.Service.HealthCheck) 用来判断 gateway 是否真正
// ready —— K8s 报 pod Running 不代表 :18789 已经 listen 完, 更不代表 connect
// handshake 已经走通; 早把 publish 让进去就会出现 chat.send 时 i/o timeout。
//
// **故意不重试**: 探活语义就是「现在能不能用」, 失败由调用方退避。
// 调用方传短超时 ctx (如 3 秒) 用于轮询, 避免拉长前端 loading。
func (c *Client) Probe(ctx context.Context, ep Endpoint) error {
	if ep.HTTPURL == "" {
		return fmt.Errorf("gatewayws.Probe: empty endpoint URL")
	}
	conn, err := c.dialAndHandshake(ctx, ep)
	if err != nil {
		return err
	}
	_ = conn.Close()
	return nil
}

// Call 打开一条 WS、做完 connect 握手、发送一条 RPC、等响应、关闭 WS。
// 期间收到的所有广播事件被默默丢弃 —— 这适用于 cron / skills 这类"请求-响应"型 RPC。
// 如果需要消费事件, 请用 CallStream。
func (c *Client) Call(ctx context.Context, ep Endpoint, method string, params interface{}) (json.RawMessage, error) {
	if ep.HTTPURL == "" {
		return nil, fmt.Errorf("gatewayws.Call: empty endpoint URL")
	}
	conn, err := c.dialAndHandshake(ctx, ep)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	reqID := uuid.New().String()
	if err := conn.WriteJSON(wsRequestFrame{Type: "req", ID: reqID, Method: method, Params: params}); err != nil {
		return nil, fmt.Errorf("ws write request: %w", err)
	}

	deadline := time.Now().Add(c.defaultRPCTimeout)
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}
		_ = conn.SetReadDeadline(deadline)
		_, msg, readErr := conn.ReadMessage()
		if readErr != nil {
			return nil, fmt.Errorf("ws read response: %w", readErr)
		}
		f, parsed := parseFrame(msg)
		if !parsed {
			continue
		}
		if !f.Reply || f.ReqID != reqID {
			continue // 丢弃广播 / 其他响应
		}
		if !f.OK {
			return nil, fmt.Errorf("gateway rpc %q failed: %s", method, string(f.Error))
		}
		return f.Payload, nil
	}
}

// CallStream 打开一条 WS、做完 connect 握手、依次发出 pre 列表里的预备请求
// (如 sessions.messages.subscribe), 再发出主请求 (method, params)。从这一刻起,
// **所有**收到的帧 (包括 pre/主请求的响应、以及广播事件) 按顺序写到返回的 channel。
//
// 调用方应在自己的 goroutine 里读取 channel, 并:
//   - 当读到自己关心的"终止信号"(如 chat.send 返回 + completed) 调用 cancel() 收尾;
//   - 或简单地读到 channel 关闭即可。
//
// channel 在以下任一情况关闭并清理 WS:
//   - ctx 被取消
//   - WS 读到 EOF / close
//   - 超过 c.defaultStreamLimit
//
// 注意: CallStream 不解释任何业务事件名, 全部原样透传 Frame。
//
// 本批 2C 不调用 CallStream (chat 留 Batch 2D); 接口保留 + 最小单测覆盖。
func (c *Client) CallStream(
	ctx context.Context,
	ep Endpoint,
	pre []Request,
	method string,
	params interface{},
) (<-chan Frame, context.CancelFunc, error) {
	if ep.HTTPURL == "" {
		return nil, nil, fmt.Errorf("gatewayws.CallStream: empty endpoint URL")
	}

	streamCtx, cancel := context.WithTimeout(ctx, c.defaultStreamLimit)

	conn, err := c.dialAndHandshake(streamCtx, ep)
	if err != nil {
		cancel()
		return nil, nil, err
	}

	// Write pre requests before starting the stream reader; required mutations must ACK first.
	// (gorilla/websocket 不支持并发 Write, 写之前不能开 reader。)
	for i, r := range pre {
		reqID := uuid.New().String()
		if err := conn.WriteJSON(wsRequestFrame{Type: "req", ID: reqID, Method: r.Method, Params: r.Params}); err != nil {
			conn.Close()
			cancel()
			return nil, nil, fmt.Errorf("ws write pre request[%d]=%s: %w", i, r.Method, err)
		}
		if r.RequireSuccess {
			stop := context.AfterFunc(streamCtx, func() { _ = conn.Close() })
			deadline := time.Now().Add(c.defaultRPCTimeout)
			if limit, ok := streamCtx.Deadline(); ok && limit.Before(deadline) {
				deadline = limit
			}
			_ = conn.SetReadDeadline(deadline)
			for {
				_, message, readErr := conn.ReadMessage()
				if readErr != nil {
					stop()
					conn.Close()
					cancel()
					return nil, nil, fmt.Errorf("gateway required pre-request %q not acknowledged: %w", r.Method, readErr)
				}
				frame, parsed := parseFrame(message)
				if !parsed || !frame.Reply || frame.ReqID != reqID {
					continue
				}
				if !frame.OK {
					stop()
					conn.Close()
					cancel()
					return nil, nil, fmt.Errorf("%w: %s", ErrRequiredRequestRejected, r.Method)
				}
				break
			}
			stop()
		}
	}
	if err := conn.WriteJSON(wsRequestFrame{Type: "req", ID: uuid.New().String(), Method: method, Params: params}); err != nil {
		conn.Close()
		cancel()
		return nil, nil, fmt.Errorf("ws write main request: %w", err)
	}

	const (
		// readDeadline: 单次 Read 的最长无任何字节到达时间。模型思考期 + 工具调用期
		// 会有静默段, 30s 太短; 上调到 5min; 保活由下面的 ping/pong 维持。
		readDeadline = 5 * time.Minute
		// pingInterval: 服务端常见 idle close 阈值 60-120s, 我们 30s 一发 ping。
		pingInterval = 30 * time.Second
	)

	// gorilla/websocket 不支持并发 Write, 单独一条 writer goroutine 串行 ping。
	writeCh := make(chan struct{}, 1)
	stopWriter := make(chan struct{})

	conn.SetPongHandler(func(string) error {
		_ = conn.SetReadDeadline(time.Now().Add(readDeadline))
		return nil
	})
	_ = conn.SetReadDeadline(time.Now().Add(readDeadline))

	go func() {
		t := time.NewTicker(pingInterval)
		defer t.Stop()
		for {
			select {
			case <-stopWriter:
				return
			case <-streamCtx.Done():
				return
			case <-t.C:
				select {
				case writeCh <- struct{}{}:
				default:
				}
			case <-writeCh:
				_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
				if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
					return
				}
			}
		}
	}()

	out := make(chan Frame, 32)
	go func() {
		defer close(out)
		defer close(stopWriter)
		defer conn.Close()
		for {
			select {
			case <-streamCtx.Done():
				return
			default:
			}
			_, msg, readErr := conn.ReadMessage()
			if readErr != nil {
				return
			}
			_ = conn.SetReadDeadline(time.Now().Add(readDeadline))
			f, parsed := parseFrame(msg)
			if !parsed {
				continue
			}
			select {
			case out <- f:
			case <-streamCtx.Done():
				return
			}
		}
	}()

	return out, cancel, nil
}

// dialAndHandshake 建 WS、读 connect.challenge、发 connect、等 hello-ok。
// 返回握手成功且立即可用于业务 RPC 的 *websocket.Conn。失败会关闭 conn。
func (c *Client) dialAndHandshake(ctx context.Context, ep Endpoint) (*websocket.Conn, error) {
	wsURL, origin, err := httpToWS(ep.HTTPURL)
	if err != nil {
		return nil, err
	}

	dialer := websocket.Dialer{HandshakeTimeout: c.handshakeTimeout}
	header := http.Header{}
	if ep.Bearer != "" {
		header.Set("Authorization", "Bearer "+ep.Bearer)
	}
	header.Set("Origin", origin)

	conn, _, err := dialer.DialContext(ctx, wsURL, header)
	if err != nil {
		return nil, fmt.Errorf("ws dial: %w", err)
	}

	// 1) connect.challenge
	_ = conn.SetReadDeadline(time.Now().Add(c.handshakeTimeout))
	_, challengeMsg, err := conn.ReadMessage()
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("ws read connect.challenge: %w", err)
	}
	var challenge struct {
		Type  string `json:"type"`
		Event string `json:"event"`
	}
	_ = json.Unmarshal(challengeMsg, &challenge)
	if challenge.Event != "connect.challenge" {
		conn.Close()
		return nil, fmt.Errorf("expected connect.challenge, got event=%q type=%q", challenge.Event, challenge.Type)
	}

	// 2) send connect
	connectID := uuid.New().String()
	connectReq := wsRequestFrame{
		Type:   "req",
		ID:     connectID,
		Method: "connect",
		Params: map[string]interface{}{
			"minProtocol": 3,
			"maxProtocol": 3,
			"client": map[string]interface{}{
				"id":         c.clientID,
				"version":    c.clientVersion,
				"platform":   c.clientPlatform,
				"mode":       c.clientMode,
				"instanceId": uuid.New().String(),
			},
			"role":   "operator",
			"scopes": c.scopes,
			"auth":   map[string]string{"token": ep.Bearer},
			// 必须声明 tool-events capability, 否则 OpenClaw chat.send 不会把此连接
			// 登记进 toolEventRecipients, server-chat 分发 stream=item / tool /
			// command_output 帧时会跳过我们 (只走 broadcastToConnIds(recipients))。
			// 缺这一行会出现: assistant / lifecycle 帧能收, 但 tool 帧全吞 ——
			// 前端 timeline 看不到任何工具调用进度。来源: legacy 实测踩坑。
			"caps":      []string{"tool-events"},
			"userAgent": "agent-bus-backend",
			"locale":    "en",
		},
	}
	if err := conn.WriteJSON(connectReq); err != nil {
		conn.Close()
		return nil, fmt.Errorf("ws write connect: %w", err)
	}

	// 3) wait for connect reply (跳过中途的 presence/tick 事件帧)
	_ = conn.SetReadDeadline(time.Now().Add(c.handshakeTimeout))
	for i := 0; i < 16; i++ { // 16 ≈ 容忍服务端在握手响应前推几条 tick
		_, msg, readErr := conn.ReadMessage()
		if readErr != nil {
			conn.Close()
			return nil, fmt.Errorf("ws read connect response: %w", readErr)
		}
		f, ok := parseFrame(msg)
		if !ok || !f.Reply || f.ReqID != connectID {
			continue
		}
		if !f.OK {
			conn.Close()
			return nil, fmt.Errorf("ws connect rejected: %s", string(f.Error))
		}
		return conn, nil
	}
	conn.Close()
	return nil, fmt.Errorf("ws connect: never received reply within handshake budget")
}

// httpToWS 把 http(s)://host:port 转成 ws(s)://host:port/ws, 并返回 origin。
func httpToWS(httpURL string) (wsURL, origin string, err error) {
	switch {
	case strings.HasPrefix(httpURL, "https://"):
		return "wss" + httpURL[5:] + "/ws", httpURL, nil
	case strings.HasPrefix(httpURL, "http://"):
		return "ws" + httpURL[4:] + "/ws", httpURL, nil
	default:
		return "", "", fmt.Errorf("gatewayws: unsupported scheme in url %q", httpURL)
	}
}
