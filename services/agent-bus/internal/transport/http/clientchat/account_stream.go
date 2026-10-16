// Package bus — account_stream.go
//
// Batch 3A T3.2 + T3.3 + T3.4: 账号级 SSE 端点
//
//	GET /api/agent-bus/v1/conversations/stream
//
// 单连接接收 caller 所有 conversation 的事件; 客户端按 payload conversation_uuid /
// room_uuid 路由到对应窗口. 不带任何 query (T3.5 stop / T3.6 retry 也不挂在这里).
//
// 兼容:
//   - Last-Event-ID 头 (RFC HTML5 spec): 服务端从该 ID 后回放 buffer; buffer miss
//     → 发 `event: connected` payload `{gap: true}`, 客户端 fallback 调
//     GET /chat/conversations/{uuid}/messages 拉补.
//   - 心跳: 默认 15s 一次 (env AGBUS_CHAT_SSE_HEARTBEAT 覆盖); 写一行 ":heartbeat" 注释帧
//     让浏览器/proxies 不超时断线.
//
// T3.4 多设备:
//   - 进来时往 Redis ZSET account:<id>:sse_conns 注册连接, 越界 (默认 5) 时通过
//     bus:cmd:kick:<owner_node> 通知 owner 节点断老连接.
//   - 自己节点订阅 bus:cmd:kick:<self_node> 收到 kick 命令时关掉本地 conn (本文件维护
//     in-process registry, 由 main / bootstrap 装 KickListener).
//
// 重要: 任何 SSE event 的 id: 字段都是 Redis Streams ID (Fanout 分配), 不用业务 UUID
// (Q1 决策, batch-3 §4.1).

package clientchat

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/id"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	svcchat "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
)

// AccountStreamConfig 控制账号级 SSE 行为. cmd/bus 装 Handlers 时填默认值.
type AccountStreamConfig struct {
	// HeartbeatInterval SSE :heartbeat 间隔; 0 视为禁用 (慎用, 浏览器 60s+ 不收任何字节会断).
	HeartbeatInterval time.Duration
	// MaxConnPerAccount 单账号最大并发连接; 默认 5; 越界时踢最老.
	MaxConnPerAccount int
	// Logger 必填.
	Logger *log.Logger
}

// AccountStreamMiddleware 把 chat.Fanout / NodeID / Config 串到一起, 让 router 注册时
// 直接拿一个 http.Handler.
//
// 它维护本节点活跃 SSE 连接的 in-process map, 用于 SubscribeKick 收到 kick 命令时找到
// 对应连接并关闭. registry key 是 fanout 生成的 conn_id (ULID).
type AccountStreamMiddleware struct {
	chat   svcchat.Service
	cfg    AccountStreamConfig
	nodeID string

	mu        sync.Mutex
	conns     map[string]*activeAccountConn // conn_id → 活跃连接
	kickCh    <-chan svcchat.KickCommand
	kickStop  func()
	startOnce sync.Once
}

type activeAccountConn struct {
	connID    string
	accountID int64
	tenantID  int64              // 3A 返修 #1: kick / deregister 需要 tenant 维度.
	cancel    context.CancelFunc // 关闭此 SSE 连接的 ctx cancel
}

// NewAccountStreamMiddleware 构造; 调 Start(ctx) 启动 kick listener.
func NewAccountStreamMiddleware(chat svcchat.Service, cfg AccountStreamConfig) *AccountStreamMiddleware {
	if cfg.HeartbeatInterval == 0 {
		cfg.HeartbeatInterval = 15 * time.Second
	}
	if cfg.MaxConnPerAccount == 0 {
		cfg.MaxConnPerAccount = 5
	}
	if cfg.Logger == nil {
		cfg.Logger = log.Default()
	}
	return &AccountStreamMiddleware{
		chat:   chat,
		cfg:    cfg,
		nodeID: chat.NodeID(),
		conns:  map[string]*activeAccountConn{},
	}
}

// Start 订阅 bus:cmd:kick:<selfNodeID> + 起 worker, 直至 ctx 取消.
//
// 多次调用 idempotent (sync.Once). cmd/bus shutdown 时通过 ctx cancel 让 listener 退出.
func (m *AccountStreamMiddleware) Start(ctx context.Context) {
	m.startOnce.Do(func() {
		fan := m.chat.AccountFanout()
		ch, cancel, err := fan.SubscribeKick(ctx, m.nodeID)
		if err != nil {
			m.cfg.Logger.Error(ctx, "account-stream: subscribe kick failed", "node_id", m.nodeID, "err", err)
			return
		}
		m.kickCh = ch
		m.kickStop = cancel
		go m.kickLoop(ctx)
	})
}

// Stop 关闭 kick listener. cmd/bus shutdown 调用.
func (m *AccountStreamMiddleware) Stop() {
	if m.kickStop != nil {
		m.kickStop()
	}
}

// kickLoop 处理跨节点 kick 命令; 找到 connID 对应的活跃连接, 调它的 cancel.
//
// 3A 返修 #3: 本地 conn 取消会触发 SSE handler 的 defer deregister, 由后者
// RemoveConnection 清掉 ZSET. 这里只关 ctx, 不直接动 fanout / ZSET, 避免双重清理.
//
// 3A 返修 #1: KickCommand 现在带 tenantID, 进一步保证不会误关同 connID 的其它租户连接
// (虽然 connID 是 24 hex 1e29 空间几乎不会撞, 显式 tenant 比对更稳).
func (m *AccountStreamMiddleware) kickLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case cmd, ok := <-m.kickCh:
			if !ok {
				return
			}
			m.cfg.Logger.Info(ctx, "account-stream: kick command received",
				"tenant_id", cmd.TenantID, "account_id", cmd.AccountID, "conn_id", cmd.ConnID, "reason", cmd.Reason)
			m.mu.Lock()
			conn, exists := m.conns[cmd.ConnID]
			m.mu.Unlock()
			if !exists {
				// 连接已不在本节点 (可能 deregister 先于 kick 到达, 或路由信息 stale).
				// 不动 ZSET, 让原 owner 节点 / 下次超限 register 重新决策.
				continue
			}
			// 显式校验 tenant + account 一致, 防御性: 若 connID 在本节点但属于另一对
			// (tenant,account), 不关 (理论上不会发生).
			if conn.tenantID != cmd.TenantID || conn.accountID != cmd.AccountID {
				m.cfg.Logger.Warn(ctx, "account-stream: kick mismatch (tenant/account)",
					"cmd_tenant", cmd.TenantID, "cmd_account", cmd.AccountID,
					"local_tenant", conn.tenantID, "local_account", conn.accountID,
					"conn_id", cmd.ConnID)
				continue
			}
			// 触发 SSE handler ctx 取消; defer deregister 会清 ZSET / owner key.
			conn.cancel()
		}
	}
}

// register 把连接登记到本节点 in-process map + Redis ZSET; 越界时驱逐最老.
//
// 3A 返修 #1: tenant + account 双重分区, 跨租户隔离.
// 3A 返修 #3: 远端驱逐**不**预删 ZSET; 仅在 owner==self 时本地 cancel 让 deregister 清,
// 否则 PublishKick → 等对端 deregister. PublishKick 失败 ZSET 仍保留, 下次超限会再算"最旧".
//
// 注意 connID 是新连接的; "踢"是踢老连接, 新连接保留.
func (m *AccountStreamMiddleware) register(ctx context.Context, accountID, tenantID int64, connID string, cancel context.CancelFunc) error {
	fan := m.chat.AccountFanout()
	if err := fan.RegisterConnection(ctx, accountID, tenantID, connID, m.nodeID, time.Now()); err != nil {
		return err
	}
	m.mu.Lock()
	m.conns[connID] = &activeAccountConn{connID: connID, accountID: accountID, tenantID: tenantID, cancel: cancel}
	m.mu.Unlock()

	// 超限检查: ZCARD > Max → 驱逐最老. 防止死循环: 跟踪上次踢过的 connID, 同一连接连
	// 续两轮还在 ZSET 头部就退出 (说明 owner 节点没响应, 不再重试踢同一目标, 等
	// connOwnerTTL 自然过期).
	lastTriedKick := ""
	for {
		n, err := fan.CountConnections(ctx, accountID, tenantID)
		if err != nil {
			m.cfg.Logger.Warn(ctx, "account-stream: count conns failed", "tenant_id", tenantID, "account_id", accountID, "err", err)
			return nil
		}
		if n <= int64(m.cfg.MaxConnPerAccount) {
			break
		}
		oldestID, ownerNode, ok, err := fan.OldestConnection(ctx, accountID, tenantID)
		if err != nil {
			m.cfg.Logger.Warn(ctx, "account-stream: oldest conn lookup failed", "tenant_id", tenantID, "account_id", accountID, "err", err)
			return nil
		}
		if !ok || oldestID == connID {
			// 没找到 / 最旧就是自己 → 不踢自己, 等下条新连接再算.
			return nil
		}
		if ownerNode == m.nodeID {
			// 本地连接: 直接 cancel, defer deregister 会清 ZSET/owner key.
			m.mu.Lock()
			conn, exists := m.conns[oldestID]
			m.mu.Unlock()
			if exists {
				m.cfg.Logger.Info(ctx, "account-stream: kicking local oldest conn",
					"tenant_id", tenantID, "account_id", accountID, "conn_id", oldestID)
				conn.cancel()
				// 等一个非常短的间隔让 deregister 跑完 ZREM (避免下一轮 CountConnections
				// 还看到老 conn 又走一次 kick 流程); 但为了不阻塞 register, 这里直接 break
				// — 下一次 register 来时会自然评估.
				return nil
			}
			// in-process map 没找到 (deregister 先一步), ZSET 可能还有 stale → 视作 stale 清掉.
			_ = fan.RemoveConnection(ctx, accountID, tenantID, oldestID)
			continue
		}

		// 远端连接: 仅 PublishKick, **不**预删 ZSET.
		// 若 owner key 缺失 (ownerNode==""), 视为 stale → 直接 ZREM, 不发 kick.
		if ownerNode == "" {
			m.cfg.Logger.Info(ctx, "account-stream: stale conn (owner missing), removing", "tenant_id", tenantID, "account_id", accountID, "conn_id", oldestID)
			_ = fan.RemoveConnection(ctx, accountID, tenantID, oldestID)
			continue
		}
		// 防死循环: 同一 oldestID 连续两轮还在最旧, owner 已发过 kick → 不再重试.
		if lastTriedKick == oldestID {
			m.cfg.Logger.Warn(ctx, "account-stream: kick already published, owner not responding; giving up this round",
				"tenant_id", tenantID, "account_id", accountID, "conn_id", oldestID, "owner", ownerNode)
			return nil
		}
		if err := fan.PublishKick(ctx, accountID, tenantID, oldestID, ownerNode); err != nil {
			m.cfg.Logger.Warn(ctx, "account-stream: publish kick failed (ZSET retained for retry)",
				"tenant_id", tenantID, "account_id", accountID, "conn_id", oldestID, "owner", ownerNode, "err", err)
			// 不预删 ZSET; 下一次 register 超限会重算.
			return nil
		}
		lastTriedKick = oldestID
		// 给对端一点时间响应 deregister; 这里不强 sleep, 直接进下一轮 Count;
		// 如果对端没响应, lastTriedKick 守卫会兜底.
	}
	return nil
}

// deregister SSE handler 退出时清理 (无论是正常关 / kick / ctx cancel).
func (m *AccountStreamMiddleware) deregister(ctx context.Context, accountID, tenantID int64, connID string) {
	m.mu.Lock()
	delete(m.conns, connID)
	m.mu.Unlock()
	if err := m.chat.AccountFanout().RemoveConnection(ctx, accountID, tenantID, connID); err != nil {
		m.cfg.Logger.Warn(ctx, "account-stream: deregister conn failed", "tenant_id", tenantID, "account_id", accountID, "conn_id", connID, "err", err)
	}
}

// Handle 是注册到 mux 的 http.HandlerFunc. caller scope = tenant member (router 已挂
// authT middleware).
func (m *AccountStreamMiddleware) Handle(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	if accID == 0 {
		encode.JSONError(w, apperr.ErrUnauthorized.Withf("account required"))
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming not supported", http.StatusInternalServerError)
		return
	}

	connCtx, cancel := context.WithCancel(r.Context())
	defer cancel()

	// Last-Event-ID 头按 SSE 规范 (大小写 insensitive); 客户端给了就回放, 没给就空.
	lastEventID := strings.TrimSpace(r.Header.Get("Last-Event-ID"))

	events, fanCancel, gap, err := m.chat.SubscribeAccount(connCtx, accID, tid, lastEventID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	defer fanCancel()

	// conn_id: 24 hex chars (96 bits 随机); ZSET member + 本地 registry 用. 不需要全局
	// 唯一性 ULID 等级, 但要避免极端碰撞.
	connID, _ := id.RandomHex(12)
	if connID == "" {
		connID = fmt.Sprintf("conn-%d", time.Now().UnixNano())
	}
	if err := m.register(connCtx, accID, tid, connID, cancel); err != nil {
		m.cfg.Logger.Warn(connCtx, "account-stream: register conn failed",
			"tenant_id", tid, "account_id", accID, "conn_id", connID, "err", err)
		// register 失败仍允许连接继续 (Redis 抖动不阻塞客户端); 多设备 cap 暂时失效, 由
		// 后续 register 重新评估.
	}
	defer m.deregister(context.Background(), accID, tid, connID)

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no") // 防止 nginx 缓冲 SSE

	// connected 控制事件: 让客户端立刻知道连接已就绪 + 是否需要 fallback 拉 history.
	connPayload := map[string]any{
		"server_time": time.Now().UTC().Format(time.RFC3339Nano),
		"node_id":     m.nodeID,
		"conn_id":     connID,
		"gap":         gap, // true 时客户端应拉 /chat/conversations/{uuid}/messages 补
	}
	writeSSE(w, "", "connected", connPayload)
	flusher.Flush()

	heartbeat := time.NewTicker(m.cfg.HeartbeatInterval)
	defer heartbeat.Stop()

	fan := m.chat.AccountFanout()

	for {
		select {
		case <-connCtx.Done():
			return
		case <-heartbeat.C:
			// 3A 返修 #2: 每个 heartbeat 刷一次 ZSET / owner key TTL, 保持 active 连接
			// 不会因 connOwnerTTL 过期而消失. 失败仅日志, 不影响客户端.
			if err := fan.RefreshConnection(connCtx, accID, tid, connID); err != nil {
				m.cfg.Logger.Warn(connCtx, "account-stream: refresh conn ttl failed",
					"tenant_id", tid, "account_id", accID, "conn_id", connID, "err", err)
			}
			// SSE 注释行 ":xxx\n\n" 客户端 EventSource 不会触发回调, 但能保活 TCP / 防 proxy 60s 断.
			_, _ = w.Write([]byte(":heartbeat\n\n"))
			flusher.Flush()
		case ev, alive := <-events:
			if !alive {
				return
			}
			// payload 已是 json.RawMessage (StreamEvent JSON); 直接 inline.
			writeSSERaw(w, ev.EventID, "", ev.Payload)
			flusher.Flush()
			// 账号级 SSE 不在终态自动断 (单条 message 终态不代表账号要断 SSE), 与 /chat/stream 不同.
		}
	}
}

// writeSSE 写一帧 SSE; data 字段做 json.Marshal.
func writeSSE(w http.ResponseWriter, id, event string, data any) {
	if id != "" {
		_, _ = w.Write([]byte("id: " + id + "\n"))
	}
	if event != "" {
		_, _ = w.Write([]byte("event: " + event + "\n"))
	}
	b, _ := json.Marshal(data)
	_, _ = w.Write([]byte("data: "))
	_, _ = w.Write(b)
	_, _ = w.Write([]byte("\n\n"))
}

// writeSSERaw 写一帧 SSE; data 是已 marshal 的 JSON, 不再 escape.
func writeSSERaw(w http.ResponseWriter, id, event string, data []byte) {
	if id != "" {
		_, _ = w.Write([]byte("id: " + id + "\n"))
	}
	if event != "" {
		_, _ = w.Write([]byte("event: " + event + "\n"))
	}
	_, _ = w.Write([]byte("data: "))
	_, _ = w.Write(data)
	_, _ = w.Write([]byte("\n\n"))
}

// 保留 fmt 引用 (内部诊断格式化).
var _ = fmt.Sprintf
