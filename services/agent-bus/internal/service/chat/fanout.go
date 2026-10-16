// Package chat — fanout.go
//
// Batch 3A T3.1 / T3.2 / T3.3 / T3.4: 把 chat 的事件分发从 batch 2D/2E 的进程内 map (hub)
// 抽到 Fanout 接口, 让 Bus 多副本部署成为可能 (修复
// docs/pitfalls/chat-hub-single-node-deviation.md 登记的偏离).
//
// 两个实现:
//   - LocalFanout: 进程内 map + sync 锁, 仅供单测 / dev 模式; 与原 hub 行为等价.
//   - RedisFanout: 跨节点 Redis pub/sub + Redis Streams 回放 buffer + ZSET 多设备 registry.
//     生产部署的默认实现; env AGBUS_CHAT_FANOUT_BACKEND=redis 时强制装载.
//
// 3A 返修后 (Codex review #1) 账号级 channel / buffer / connection registry 必须
// **tenant + account 双重分区**, 防止同一 account 跨租户串台. 旧的纯 account 路径已
// 全部下线.
//
// Redis 通道 / key 命名 (全部精确字符串, **无 glob / 无 PSUBSCRIBE**, 与
// docs/tasks/batch-3-m4-chat-completion.md §4.2 + 3A Codex review #1 一致):
//
//	chat:stream:<stream_id>                                       per-stream pub/sub (legacy /chat/stream 兼容)
//	chat:stream:<stream_id>:buf                                   per-stream Redis Streams 回放 buffer (MAXLEN ~200)
//	chat:stream:<stream_id>:meta                                  per-stream owner / node_id HASH (TTL 1h)
//	tenant:<tenant_id>:account:<account_id>:events                账号级 pub/sub (1 SSE 连接 1:1 SUBSCRIBE)
//	tenant:<tenant_id>:account:<account_id>:events_buf            账号级 Redis Streams 回放 buffer (MAXLEN ~1000)
//	tenant:<tenant_id>:account:<account_id>:sse_conns             账号级多设备连接 ZSET (member=conn_id, score=ts_ms)
//	tenant:<tenant_id>:account:<account_id>:sse_conn:<conn_id>    连接 → owner_node_id STRING (TTL=ConnTTL, heartbeat refresh)
//	bus:cmd:kick:<bus_node_id>                                    kick 跨节点 (T3.4; 节点启动时 SUBSCRIBE)
//	bus:cmd:cancel:<bus_node_id>                                  stop 跨节点 (T3.5, 本批仅在 RedisFanout 留接口
//	                                                              预留, 真正订阅 + handler 接到 T3.5 一起做)
//
// **SSE id 字段策略** (Q1 决策, batch-3 §4.1):
//   - 账号级 SSE: id: <Redis Streams ID>, 客户端 Last-Event-ID 直接用该 ID 回放
//   - per-stream SSE (legacy): 沿用现有协议, 不强制带 id (兼容性优先)
//   - 业务 UUID 如埋点 / 关联日志, 走 payload event_uuid 字段, **不**写到 SSE id
package chat

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

// AccountEvent 是账号级 SSE 推到客户端的事件 envelope.
//
//   - EventID  Redis Streams ID (e.g. "1715900400000-0"), 作为 SSE 的 id: 字段, 客户端
//     断线重连时把它放进 Last-Event-ID 头, 服务端从该 ID 之后回放.
//     LocalFanout 也会生成单调递增的伪 Streams ID 以便 dev / 单测路径对齐.
//   - Payload  业务 JSON, 通常是 StreamEvent 序列化, 也可以是 connected/gap 等控制事件.
type AccountEvent struct {
	EventID string          `json:"event_id"`
	Payload json.RawMessage `json:"payload"`
}

// KickCommand 通过 bus:cmd:kick:<node> 下发, 告诉 owner 节点关掉某账号的某个连接 (T3.4).
//
// 3A 返修后 (Codex review #1): TenantID 字段加入, owner 节点查 in-process registry 时
// 仍只用 ConnID, 但 tenant 维度保证不会误关同 connID 的其它租户连接 (理论上 connID 是 ULID
// 不会撞, 但显式 tenant 隔离更稳).
type KickCommand struct {
	AccountID int64  `json:"account_id"`
	TenantID  int64  `json:"tenant_id"`
	ConnID    string `json:"conn_id"`
	// Reason 仅用于日志 / 客户端 connected{kicked:true,reason:"max_devices"}.
	Reason string `json:"reason,omitempty"`
}

// CancelCommand 通过 bus:cmd:cancel:<bus_node_id> 下发 (Batch 3B T3.5), 让 owner 节点
// 取消正在跑的 chat agent stream.
//
// StreamID 是首要路由键 (与 message_streams.stream_id 一致); 其他字段是诊断 / 防误关:
//   - MessageUUID  与 stream_id 对齐, owner 节点查 in-process map 后做交叉校验
//   - TenantID     防御性, 校验 owner 节点本地 stream 归属一致
//   - AccountID    同上
//   - CancelToken  M4 §3.2 字段, 3B 暂不消费 (owner 节点本地 cancel 不需鉴权); 留兼容
//   - Reason       审计 / 日志, 例如 "user_stop"
type CancelCommand struct {
	StreamID    string `json:"stream_id"`
	MessageUUID string `json:"message_uuid"`
	TenantID    int64  `json:"tenant_id"`
	AccountID   int64  `json:"account_id"`
	CancelToken string `json:"cancel_token,omitempty"`
	Reason      string `json:"reason,omitempty"`
}

// Fanout 抽象 chat / room SSE 事件分发. 见包注释顶部 Redis 通道命名表.
//
// 所有方法应当短 (单次 Redis IO 量级); 不在内部阻塞业务流.
// LocalFanout / RedisFanout 都不持有调用者的请求 ctx; SubscribeAccount 等返回的
// channel 由调用者通过 cancel func 显式关闭, 避免泄漏.
type Fanout interface {
	// Register 在 chat.Send 创建 streaming agent message **之前**调用 (Codex review #4
	// fail-closed), 把 streamID → (account, tenant, node) 三元组绑定. SubscribeWithOwner
	// 用 owner 信息做归属校验; nodeID 是 T3.5 stop 跨节点路由的依据 (本批 RedisFanout
	// 先把 nodeID 写到 meta HASH 落位, 实际 cancel 路径接 T3.5).
	//
	// 返回 error 时 caller (chat.runAgentInternal) **必须** 直接 fail, 不许继续启动
	// stream goroutine (否则 /chat/stream 兼容端点查 owner 失败).
	Register(ctx context.Context, streamID string, accountID, tenantID int64, nodeID string) error

	// Owner 返回 streamID 注册时记录的 (account, tenant). ok=false 表示 stream 尚未 Register
	// 或已被 Close + grace TTL 过期.
	Owner(ctx context.Context, streamID string) (accountID, tenantID int64, ok bool, err error)

	// Publish 把一条事件同时投递到:
	//   1. per-stream pub/sub (chat:stream:<id>) + per-stream Redis Streams buffer (chat:stream:<id>:buf)
	//   2. account-level pub/sub (tenant:<tenantID>:account:<accountID>:events) + account 级 Streams buffer
	//      (tenant:<tenantID>:account:<accountID>:events_buf), 后者负责 Last-Event-ID 回放.
	//
	// **tenantID 必须传**: 3A 返修 #1 起 account-level channel/buffer 按 tenant+account
	// 双重分区, 缺 tenantID 视为编程错误 → 跳过账号级 publish, 仅 per-stream.
	Publish(ctx context.Context, streamID string, accountID, tenantID int64, ev StreamEvent) error

	// Subscribe per-stream 订阅 (legacy /chat/stream?stream_id=... 端点兼容).
	// 实现必须先把 Register 后已经发的 buffer 帧回放出去, 再切实时 (sub-after-pub 兼容).
	// cancel 关 channel 并 UNSUBSCRIBE; 调用方 defer cancel().
	Subscribe(ctx context.Context, streamID string) (<-chan StreamEvent, func(), error)

	// Close 标记 streamID 终态, 关掉所有 Subscribe 出去的 channel. 实现需保留 buffer 一小段
	// grace TTL (默认 5min), 让稍晚一点订阅的 SubscribeWithOwner 仍能拉到 final 事件.
	Close(ctx context.Context, streamID string)

	// SubscribeAccount 账号级 SSE (T3.2 + T3.3).
	//
	// 3A 返修 #1: 必须按 tenantID + accountID 双重分区, 防止同一 account 跨租户串台.
	//
	// lastEventID:
	//   - ""           只接收 LIVE 事件; 不回放, gap=false
	//   - 有效 ID 且在 buffer 内  回放 (ID, +∞) 段 + 之后 LIVE; gap=false
	//   - 有效 ID 但已被 TRIM     不回放, gap=true (返回值), 客户端应 fallback 拉 /messages
	//   - 任何无法解析的字符串    视为 ""
	//
	// 返回的 channel 中每个 AccountEvent.EventID 单调递增 (Redis Streams ID).
	// cancel 关 channel + UNSUBSCRIBE.
	SubscribeAccount(ctx context.Context, accountID, tenantID int64, lastEventID string) (events <-chan AccountEvent, cancel func(), gap bool, err error)

	// RegisterConnection 在账号级 SSE 连接进来时调用 (T3.4):
	//   - ZADD tenant:<t>:account:<a>:sse_conns <ts_ms> <conn_id>
	//   - SET  tenant:<t>:account:<a>:sse_conn:<conn_id> <nodeID> EX ConnTTL (节点崩溃兜底)
	// ts 用当前墙钟; nodeID 是本节点 bus_node_id, 用于跨节点 kick 路由.
	RegisterConnection(ctx context.Context, accountID, tenantID int64, connID, nodeID string, ts time.Time) error

	// RefreshConnection 刷新 ZSET / owner key 的 TTL (3A 返修 #2). SSE handler 在 heartbeat
	// tick 调用, 保持 active 连接 registry 不会因 connOwnerTTL 过期而消失.
	//
	// 实现必须 idempotent (连续多次调用安全), 找不到 conn 时不报错 (容忍 race: 刚被踢的连接
	// heartbeat 还在飞).
	RefreshConnection(ctx context.Context, accountID, tenantID int64, connID string) error

	// RemoveConnection 在 SSE 连接断开 (无论原因) 时清理 ZSET + 反查 STRING.
	// 即使 connID 不存在也不报错 (idempotent).
	RemoveConnection(ctx context.Context, accountID, tenantID int64, connID string) error

	// CountConnections 返回当前注册的连接数 (用于多设备超限判断).
	CountConnections(ctx context.Context, accountID, tenantID int64) (int64, error)

	// OldestConnection 返回 ZSET 最小 score 的 (connID, ownerNodeID). 未找到 ok=false.
	// ownerNodeID 通过反查 tenant:<t>:account:<a>:sse_conn:<conn_id> 拿到; 缺失时返回 "".
	OldestConnection(ctx context.Context, accountID, tenantID int64) (connID, ownerNodeID string, ok bool, err error)

	// PublishKick 通过 bus:cmd:kick:<ownerNodeID> 通知 owner 节点关掉某连接.
	//
	// 3A 返修 #3: **不**在调用前预删 ZSET; 仅当 ownerNode == self 时由 caller 直接本地
	// cancel (deregister 路径会 RemoveConnection); ownerNode != self 时仅 PublishKick,
	// 失败应让 caller 知道, ZSET 仍保留以便下次重试踢同一 conn.
	PublishKick(ctx context.Context, accountID, tenantID int64, connID, ownerNodeID string) error

	// SubscribeKick 节点启动时调用, 订阅 bus:cmd:kick:<selfNodeID> 收到 kick 命令.
	// 每个 KickCommand 由 SSE handler 消费, 在本节点查找对应 connID 的活跃连接并关闭它.
	SubscribeKick(ctx context.Context, selfNodeID string) (<-chan KickCommand, func(), error)

	// PublishCancel (Batch 3B T3.5 + 返修 #3) 通过 bus:cmd:cancel:<ownerNodeID> 通知 owner
	// 节点取消某 streamID.
	//
	// 返回 (subscriberCount, error):
	//   - subscriberCount: Redis PUBLISH 返回的"已投递订阅者数". 0 表示 owner 节点
	//     不在线/没订阅 → caller 应触发 optimisticCancel fallback (3B 返修 #3 dead-owner).
	//   - err: 序列化失败 / Redis 网络错误.
	//
	// LocalFanout 也实现同样语义: subscriberCount=1 if 注册过 SubscribeCancel, 否则 0.
	// channel 满时返回 (0, err) 让 caller fallback.
	PublishCancel(ctx context.Context, ownerNodeID string, cmd CancelCommand) (int64, error)

	// SubscribeCancel (Batch 3B T3.5) 节点启动时调用, 订阅 bus:cmd:cancel:<selfNodeID>.
	// chat.Service 持有 cancel listener goroutine, 收到 CancelCommand 后在本节点查 in-process
	// per-stream cancel func 并触发 (与 stop 自己节点的 cancel 路径合一).
	SubscribeCancel(ctx context.Context, selfNodeID string) (<-chan CancelCommand, func(), error)
}

// ----- 错误 / 常量 -----

// streamMetaTTL per-stream owner meta HASH 的 TTL. 长一点比 stream lifetime (单聊 ~10min) 大,
// 防止 Close 后 SubscribeWithOwner 立刻拉 owner 信息时 HASH 已没.
const streamMetaTTL = 1 * time.Hour

// streamBufTTL per-stream buffer 的 TTL. 与 Close 后的 grace 一致 (~5min).
const streamBufTTL = 5 * time.Minute

// accountBufTTL 账号级 buffer 的 TTL. Last-Event-ID 回放窗口 ~10min.
const accountBufTTL = 10 * time.Minute

// accountBufMaxLen 账号级 buffer 最长保留事件数 (~5 分钟 1 event/s 高峰).
const accountBufMaxLen = 1000

// perStreamBufMaxLen per-stream buffer 最长保留事件数 (~一次 chat 通常 < 200 个 delta).
const perStreamBufMaxLen = 200

// connOwnerTTL 连接 → owner_node 反查 STRING 的 TTL. SSE handler 每个 heartbeat
// (默认 15s) 调 RefreshConnection 刷新; 节点崩溃时 connOwnerTTL 内自然过期.
//
// 注意: 必须远大于 heartbeat 间隔, 否则 active 连接也会被误清.
const connOwnerTTL = 5 * time.Minute

// chSubBuffer 单个订阅 channel 的内置 buffer. 太小会丢, 太大占内存; 32 与 batch 2D hub 一致.
const chSubBuffer = 32

// errAccountEventNotInBuf SubscribeAccount lastEventID 已被 TRIM 时的内部 sentinel.
var errAccountEventNotInBuf = errors.New("fanout: last_event_id no longer in buffer")

// tenAcct 是 LocalFanout 用的复合 key (tenant + account); 防止跨租户串台 (3A 返修 #1).
type tenAcct struct {
	tenantID, accountID int64
}

// ============================================================================
// LocalFanout
// ============================================================================

// LocalFanout 进程内实现, 仅供单测 / dev. 不跨节点; 多副本部署必须用 RedisFanout.
//
// 数据结构 (3A 返修 #1 改成 tenant+account 双重分区):
//   - streams: streamID → localStream (持锁 + history + subs + owner)
//   - accountBu: (tenant, account) → ring buffer of AccountEvent
//   - accountSu: (tenant, account) → set of localAccountSub (每个对应一个 SSE 连接)
//   - connReg: (tenant, account) → map[connID]localConn
//   - kickChans: nodeID → chan KickCommand
//   - cancelChans: nodeID → chan CancelCommand (3B T3.5)
type LocalFanout struct {
	logger *log.Logger

	mu          sync.RWMutex
	streams     map[string]*localStream
	accountBu   map[tenAcct]*localAccountBuffer
	accountSu   map[tenAcct]map[*localAccountSub]struct{}
	connReg     map[tenAcct]map[string]localConn
	kickChans   map[string]chan KickCommand
	cancelChans map[string]chan CancelCommand

	// seq 给 LocalFanout 生成单调递增的伪 Streams ID, 与真实 Redis 行为对齐
	// (millisecond-prefix + sequence suffix).
	seqMu  sync.Mutex
	seqMs  int64
	seqIdx int64
}

type localStream struct {
	mu        sync.Mutex
	accountID int64
	tenantID  int64
	nodeID    string
	history   []StreamEvent
	subs      []chan StreamEvent
	closed    bool
	closedAt  time.Time
}

type localAccountBuffer struct {
	mu     sync.Mutex
	events []AccountEvent // ring; len <= accountBufMaxLen
}

// localAccountSub 3A 返修 #5: 加 mu + closed flag 防止 cancel 与 Publish 的 send-on-closed 竞态.
//
// Publish 在 trySend(ev) 中持 sub.mu 检查 closed, cancel 在 close_() 中同样持 sub.mu, 保证
// "关 channel" 与 "向 channel 发送" 互斥, 避免 panic("send on closed channel").
type localAccountSub struct {
	mu     sync.Mutex
	ch     chan AccountEvent
	closed bool
}

func (s *localAccountSub) trySend(ev AccountEvent) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	select {
	case s.ch <- ev:
	default:
		// 满了不阻塞 publish; 客户端慢吃 → 偶尔丢, 由 Last-Event-ID 兜.
	}
}

func (s *localAccountSub) close_() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.closed {
		s.closed = true
		close(s.ch)
	}
}

type localConn struct {
	connID string
	nodeID string
	ts     time.Time
	// ttlExpiresAt 模拟 Redis EX TTL; RefreshConnection 重置;
	// CountConnections / OldestConnection 调用前过滤过期项.
	ttlExpiresAt time.Time
}

// NewLocalFanout 构造一个进程内 Fanout.
func NewLocalFanout(logger *log.Logger) *LocalFanout {
	if logger == nil {
		logger = log.Default()
	}
	return &LocalFanout{
		logger:      logger,
		streams:     map[string]*localStream{},
		accountBu:   map[tenAcct]*localAccountBuffer{},
		accountSu:   map[tenAcct]map[*localAccountSub]struct{}{},
		connReg:     map[tenAcct]map[string]localConn{},
		kickChans:   map[string]chan KickCommand{},
		cancelChans: map[string]chan CancelCommand{},
	}
}

// nextLocalID 生成单调递增的伪 Streams ID, 格式与 Redis 一致 (ms-seq).
func (f *LocalFanout) nextLocalID() string {
	f.seqMu.Lock()
	defer f.seqMu.Unlock()
	now := time.Now().UnixMilli()
	if now == f.seqMs {
		f.seqIdx++
	} else {
		f.seqMs = now
		f.seqIdx = 0
	}
	return fmt.Sprintf("%d-%d", f.seqMs, f.seqIdx)
}

// Register 创建 streamID 的本地 stream 记录.
func (f *LocalFanout) Register(ctx context.Context, streamID string, accountID, tenantID int64, nodeID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.streams[streamID] = &localStream{
		accountID: accountID,
		tenantID:  tenantID,
		nodeID:    nodeID,
	}
	return nil
}

// Owner 查 stream 注册时记录的归属.
func (f *LocalFanout) Owner(ctx context.Context, streamID string) (int64, int64, bool, error) {
	f.mu.RLock()
	s, ok := f.streams[streamID]
	f.mu.RUnlock()
	if !ok {
		return 0, 0, false, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.accountID, s.tenantID, true, nil
}

// Publish 把事件同时推到 per-stream subs + account-level subs + account buffer.
//
// 3A 返修 #1: account 通道按 (tenant, account) 分区, tenantID == 0 时跳过账号级推送.
// 3A 返修 #5: snapshot subs slice 后再 trySend, 与 cancel 互斥.
func (f *LocalFanout) Publish(ctx context.Context, streamID string, accountID, tenantID int64, ev StreamEvent) error {
	// 1. per-stream fanout (保留 history 供 sub-after-pub).
	f.mu.RLock()
	s, ok := f.streams[streamID]
	f.mu.RUnlock()
	if ok {
		s.mu.Lock()
		if !s.closed {
			s.history = append(s.history, ev)
			if len(s.history) > perStreamBufMaxLen {
				// 简单 trim head, dev 模式不优化.
				s.history = s.history[len(s.history)-perStreamBufMaxLen:]
			}
			for _, c := range s.subs {
				select {
				case c <- ev:
				default:
					// 满了不阻塞 publish; 同 batch 2D hub 行为.
				}
			}
		}
		s.mu.Unlock()
	}

	// 2. account-level fanout. tenantID == 0 视为编程错误 → 跳过 (3A 返修 #1).
	if accountID == 0 || tenantID == 0 {
		if accountID != 0 && tenantID == 0 {
			f.logger.Warn(ctx, "fanout: account publish skipped (missing tenant_id)", "account_id", accountID, "stream_id", streamID)
		}
		return nil
	}
	key := tenAcct{tenantID: tenantID, accountID: accountID}
	payload, err := json.Marshal(ev)
	if err != nil {
		return fmt.Errorf("fanout: marshal account event: %w", err)
	}
	acctEv := AccountEvent{
		EventID: f.nextLocalID(),
		Payload: payload,
	}

	// 锁内做两件事: 1) 拿/建 buffer; 2) 复制当前 subs 到本地 slice (3A 返修 #5: 避免在
	// 持锁外 ranging map 时 cancel 并发删除导致 send-on-closed).
	f.mu.Lock()
	buf, ok := f.accountBu[key]
	if !ok {
		buf = &localAccountBuffer{}
		f.accountBu[key] = buf
	}
	var subSlice []*localAccountSub
	if subs := f.accountSu[key]; len(subs) > 0 {
		subSlice = make([]*localAccountSub, 0, len(subs))
		for sub := range subs {
			subSlice = append(subSlice, sub)
		}
	}
	f.mu.Unlock()

	buf.mu.Lock()
	buf.events = append(buf.events, acctEv)
	if len(buf.events) > accountBufMaxLen {
		buf.events = buf.events[len(buf.events)-accountBufMaxLen:]
	}
	buf.mu.Unlock()

	for _, sub := range subSlice {
		sub.trySend(acctEv)
	}
	return nil
}

// Subscribe per-stream 订阅; 先 replay history, 再 tail live.
func (f *LocalFanout) Subscribe(ctx context.Context, streamID string) (<-chan StreamEvent, func(), error) {
	f.mu.RLock()
	s, ok := f.streams[streamID]
	f.mu.RUnlock()
	if !ok {
		return nil, nil, errors.New("fanout: stream not found")
	}
	ch := make(chan StreamEvent, chSubBuffer)
	s.mu.Lock()
	for _, ev := range s.history {
		select {
		case ch <- ev:
		default:
		}
	}
	if s.closed {
		close(ch)
		s.mu.Unlock()
		return ch, func() {}, nil
	}
	s.subs = append(s.subs, ch)
	s.mu.Unlock()
	cancel := func() {
		s.mu.Lock()
		for i, c := range s.subs {
			if c == ch {
				s.subs = append(s.subs[:i], s.subs[i+1:]...)
				break
			}
		}
		s.mu.Unlock()
	}
	return ch, cancel, nil
}

// Close 标记 stream 终态; grace 5min 后 GC.
func (f *LocalFanout) Close(ctx context.Context, streamID string) {
	f.mu.RLock()
	s, ok := f.streams[streamID]
	f.mu.RUnlock()
	if !ok {
		return
	}
	s.mu.Lock()
	if !s.closed {
		s.closed = true
		s.closedAt = time.Now()
		for _, c := range s.subs {
			close(c)
		}
		s.subs = nil
	}
	s.mu.Unlock()
	// 异步 GC, 5min 后从 streams map 摘掉 (与 batch 2D hub 等价).
	go func() {
		time.Sleep(streamBufTTL)
		f.mu.Lock()
		delete(f.streams, streamID)
		f.mu.Unlock()
	}()
}

// SubscribeAccount 账号级 SSE (LocalFanout 简化版).
//
// 3A 返修 #1: 按 (tenant, account) 分区, 跨租户隔离.
//
// lastEventID 处理:
//   - "" → 不回放
//   - 在 buffer → 回放 (lastEventID, +∞) 段
//   - 不在 buffer (TRIM 过 / 解析失败) → gap=true, 不回放
//
// LocalFanout 没有真正的 pub/sub; 通过把 sub 注册到 accountSu map 实现 fanout 推送.
func (f *LocalFanout) SubscribeAccount(ctx context.Context, accountID, tenantID int64, lastEventID string) (<-chan AccountEvent, func(), bool, error) {
	if accountID == 0 || tenantID == 0 {
		return nil, nil, false, errors.New("fanout: account_id and tenant_id required")
	}
	key := tenAcct{tenantID: tenantID, accountID: accountID}
	sub := &localAccountSub{ch: make(chan AccountEvent, chSubBuffer)}

	f.mu.Lock()
	subs, ok := f.accountSu[key]
	if !ok {
		subs = map[*localAccountSub]struct{}{}
		f.accountSu[key] = subs
	}
	subs[sub] = struct{}{}
	buf := f.accountBu[key]
	f.mu.Unlock()

	gap := false
	if lastEventID != "" {
		// 回放: 简单线性扫 buf (dev 模式可接受).
		if buf == nil {
			gap = true
		} else {
			buf.mu.Lock()
			found := false
			for _, ev := range buf.events {
				if ev.EventID == lastEventID {
					found = true
					continue
				}
				if found {
					// 锁内 send: localAccountSub.trySend 自身有 sub.mu 保护, 这里
					// trySend 是非阻塞 select default, 安全.
					sub.trySend(ev)
				}
			}
			buf.mu.Unlock()
			if !found {
				// lastEventID 不在 buffer; 客户端应 fallback 拉 history.
				gap = true
			}
		}
	}

	cancel := func() {
		f.mu.Lock()
		if m, ok := f.accountSu[key]; ok {
			delete(m, sub)
			if len(m) == 0 {
				delete(f.accountSu, key)
			}
		}
		f.mu.Unlock()
		// 3A 返修 #5: localAccountSub.close_() 内部走 sub.mu 互斥, 防 send-on-closed race.
		sub.close_()
	}
	return sub.ch, cancel, gap, nil
}

// RegisterConnection 把连接登记到 connReg (按 tenant+account 分区).
func (f *LocalFanout) RegisterConnection(ctx context.Context, accountID, tenantID int64, connID, nodeID string, ts time.Time) error {
	key := tenAcct{tenantID: tenantID, accountID: accountID}
	f.mu.Lock()
	defer f.mu.Unlock()
	m, ok := f.connReg[key]
	if !ok {
		m = map[string]localConn{}
		f.connReg[key] = m
	}
	m[connID] = localConn{connID: connID, nodeID: nodeID, ts: ts, ttlExpiresAt: time.Now().Add(connOwnerTTL)}
	return nil
}

// RefreshConnection 重置该连接的 TTL (3A 返修 #2). 找不到 conn 时不报错.
func (f *LocalFanout) RefreshConnection(ctx context.Context, accountID, tenantID int64, connID string) error {
	key := tenAcct{tenantID: tenantID, accountID: accountID}
	f.mu.Lock()
	defer f.mu.Unlock()
	m, ok := f.connReg[key]
	if !ok {
		return nil
	}
	c, ok := m[connID]
	if !ok {
		return nil
	}
	c.ttlExpiresAt = time.Now().Add(connOwnerTTL)
	m[connID] = c
	return nil
}

// RemoveConnection idempotent (按 tenant+account 分区).
func (f *LocalFanout) RemoveConnection(ctx context.Context, accountID, tenantID int64, connID string) error {
	key := tenAcct{tenantID: tenantID, accountID: accountID}
	f.mu.Lock()
	defer f.mu.Unlock()
	if m, ok := f.connReg[key]; ok {
		delete(m, connID)
		if len(m) == 0 {
			delete(f.connReg, key)
		}
	}
	return nil
}

// CountConnections 当前账号 (tenant 内) 的活跃连接数. 过滤 ttlExpiresAt 已过的 stale 项.
func (f *LocalFanout) CountConnections(ctx context.Context, accountID, tenantID int64) (int64, error) {
	key := tenAcct{tenantID: tenantID, accountID: accountID}
	now := time.Now()
	f.mu.RLock()
	m := f.connReg[key]
	var n int64
	for _, c := range m {
		if c.ttlExpiresAt.After(now) {
			n++
		}
	}
	f.mu.RUnlock()
	return n, nil
}

// OldestConnection 返回 (tenant 内) 最旧的活跃 (connID, nodeID); 多个并列时取任一.
// 过滤 TTL 已过的项, 与 Redis EXPIRE 行为一致.
func (f *LocalFanout) OldestConnection(ctx context.Context, accountID, tenantID int64) (string, string, bool, error) {
	key := tenAcct{tenantID: tenantID, accountID: accountID}
	now := time.Now()
	f.mu.RLock()
	defer f.mu.RUnlock()
	m := f.connReg[key]
	if len(m) == 0 {
		return "", "", false, nil
	}
	var (
		oldestID   string
		oldestNode string
		oldestTS   time.Time
		first      = true
	)
	for _, c := range m {
		if !c.ttlExpiresAt.After(now) {
			continue
		}
		if first || c.ts.Before(oldestTS) {
			oldestID = c.connID
			oldestNode = c.nodeID
			oldestTS = c.ts
			first = false
		}
	}
	if first {
		return "", "", false, nil
	}
	return oldestID, oldestNode, true, nil
}

// PublishKick 把 kick 命令推到 ownerNodeID 的 channel.
//
// 找不到 channel 时返回 error (3A 返修 #3: 让 caller 知道, 不要预删 ZSET);
// 真实跨节点用 RedisFanout, LocalFanout 主要服务单测, 这里 channel 缺失视为编程错误.
func (f *LocalFanout) PublishKick(ctx context.Context, accountID, tenantID int64, connID, ownerNodeID string) error {
	f.mu.RLock()
	ch, ok := f.kickChans[ownerNodeID]
	f.mu.RUnlock()
	if !ok {
		return fmt.Errorf("fanout: no kick subscriber for node %q", ownerNodeID)
	}
	select {
	case ch <- KickCommand{AccountID: accountID, TenantID: tenantID, ConnID: connID, Reason: "max_devices"}:
		return nil
	default:
		return fmt.Errorf("fanout: kick channel full for node %q", ownerNodeID)
	}
}

// SubscribeKick 注册本节点的 kick channel.
func (f *LocalFanout) SubscribeKick(ctx context.Context, selfNodeID string) (<-chan KickCommand, func(), error) {
	if selfNodeID == "" {
		return nil, nil, errors.New("fanout: node_id required")
	}
	f.mu.Lock()
	ch, ok := f.kickChans[selfNodeID]
	if !ok {
		ch = make(chan KickCommand, chSubBuffer)
		f.kickChans[selfNodeID] = ch
	}
	f.mu.Unlock()
	cancel := func() {
		f.mu.Lock()
		if existing, ok := f.kickChans[selfNodeID]; ok && existing == ch {
			delete(f.kickChans, selfNodeID)
			close(ch)
		}
		f.mu.Unlock()
	}
	return ch, cancel, nil
}

// PublishCancel (Batch 3B T3.5 + 返修 #3) LocalFanout 实现, 服务单测.
//
// 返回 (subscriberCount, error):
//   - ownerNodeID 没注册 SubscribeCancel → (0, nil); caller 走 optimisticCancel fallback.
//   - channel 满 → (0, err); 同样让 caller fallback (兜底, 不阻塞 stop).
//   - 投递成功 → (1, nil).
func (f *LocalFanout) PublishCancel(ctx context.Context, ownerNodeID string, cmd CancelCommand) (int64, error) {
	f.mu.RLock()
	ch, ok := f.cancelChans[ownerNodeID]
	f.mu.RUnlock()
	if !ok {
		// 注意: 不返 error, 让 caller 走 fallback 路径; 这是预期场景 (owner 节点崩了 / 还没起).
		return 0, nil
	}
	select {
	case ch <- cmd:
		return 1, nil
	default:
		return 0, fmt.Errorf("fanout: cancel channel full for node %q", ownerNodeID)
	}
}

// SubscribeCancel 注册本节点的 cancel channel (3B T3.5).
func (f *LocalFanout) SubscribeCancel(ctx context.Context, selfNodeID string) (<-chan CancelCommand, func(), error) {
	if selfNodeID == "" {
		return nil, nil, errors.New("fanout: node_id required")
	}
	f.mu.Lock()
	ch, ok := f.cancelChans[selfNodeID]
	if !ok {
		ch = make(chan CancelCommand, chSubBuffer)
		f.cancelChans[selfNodeID] = ch
	}
	f.mu.Unlock()
	cancel := func() {
		f.mu.Lock()
		if existing, ok := f.cancelChans[selfNodeID]; ok && existing == ch {
			delete(f.cancelChans, selfNodeID)
			close(ch)
		}
		f.mu.Unlock()
	}
	return ch, cancel, nil
}

// ============================================================================
// RedisFanout
// ============================================================================

// RedisFanout 跨节点实现. 用 pub/sub 做实时 fanout, 用 Redis Streams 做 buffer / 回放,
// 用 ZSET 做多设备 registry, 用单独通道做 kick (T3.4) / cancel (T3.5 预留).
//
// 设计原则:
//   - 每个 SubscribeAccount(...) 持有一个独立 redis.PubSub (与文档 §4.2 "SSE 连接 1:1
//     SUBSCRIBE" 一致), 防止跨连接彼此影响.
//   - per-stream Subscribe 同样持有独立 PubSub; 来一个订一个, stream 终态 Close 时 UNSUBSCRIBE.
//   - SubscribeKick(selfNodeID) 由 cmd/bus 启动时调一次, 单连接 + 单 channel, 进程退出由
//     cancel 关闭.
//   - **绝不** PSUBSCRIBE chat:stream:* 或 account:*:events; 通道名永远精确.
type RedisFanout struct {
	logger *log.Logger
	rdb    *redis.Client
}

// NewRedisFanout 构造 RedisFanout. rdb 必须已 Ping 通; logger 用于 best-effort 错误打点.
func NewRedisFanout(rdb *redis.Client, logger *log.Logger) *RedisFanout {
	if logger == nil {
		logger = log.Default()
	}
	if rdb == nil {
		panic("RedisFanout requires non-nil redis client")
	}
	return &RedisFanout{logger: logger, rdb: rdb}
}

func streamMetaKey(streamID string) string {
	return "chat:stream:" + streamID + ":meta"
}
func streamBufKey(streamID string) string {
	return "chat:stream:" + streamID + ":buf"
}
func streamPubChan(streamID string) string {
	return "chat:stream:" + streamID
}

// 3A 返修 #1: account-level key 永远带 tenant:<t> 前缀, 跨租户分区.
func accountPubChan(tenantID, accountID int64) string {
	return fmt.Sprintf("tenant:%d:account:%d:events", tenantID, accountID)
}
func accountBufKey(tenantID, accountID int64) string {
	return fmt.Sprintf("tenant:%d:account:%d:events_buf", tenantID, accountID)
}
func accountConnsZSetKey(tenantID, accountID int64) string {
	return fmt.Sprintf("tenant:%d:account:%d:sse_conns", tenantID, accountID)
}
func accountConnOwnerKey(tenantID, accountID int64, connID string) string {
	return fmt.Sprintf("tenant:%d:account:%d:sse_conn:%s", tenantID, accountID, connID)
}
func kickChanKey(nodeID string) string {
	return "bus:cmd:kick:" + nodeID
}

// cancelChanKey (3B T3.5) per-node 跨节点 cancel pub/sub channel.
// 与 kickChanKey 同形态 (精确字符串, 不用 glob), 但语义不同: kick 关 SSE 连接,
// cancel 关正在跑的 chat agent stream.
func cancelChanKey(nodeID string) string {
	return "bus:cmd:cancel:" + nodeID
}

// Register 把 streamID 的 owner / nodeID 写到 HASH (TTL=streamMetaTTL).
func (f *RedisFanout) Register(ctx context.Context, streamID string, accountID, tenantID int64, nodeID string) error {
	key := streamMetaKey(streamID)
	pipe := f.rdb.TxPipeline()
	pipe.HSet(ctx, key, map[string]any{
		"account_id": accountID,
		"tenant_id":  tenantID,
		"node_id":    nodeID,
		"started_at": time.Now().UnixMilli(),
	})
	pipe.Expire(ctx, key, streamMetaTTL)
	if _, err := pipe.Exec(ctx); err != nil {
		return fmt.Errorf("fanout: register stream meta: %w", err)
	}
	return nil
}

// Owner 查 HASH.
func (f *RedisFanout) Owner(ctx context.Context, streamID string) (int64, int64, bool, error) {
	vals, err := f.rdb.HMGet(ctx, streamMetaKey(streamID), "account_id", "tenant_id").Result()
	if err != nil {
		return 0, 0, false, fmt.Errorf("fanout: owner hmget: %w", err)
	}
	if vals[0] == nil || vals[1] == nil {
		return 0, 0, false, nil
	}
	var accountID, tenantID int64
	if s, ok := vals[0].(string); ok {
		_, _ = fmt.Sscanf(s, "%d", &accountID)
	}
	if s, ok := vals[1].(string); ok {
		_, _ = fmt.Sscanf(s, "%d", &tenantID)
	}
	return accountID, tenantID, true, nil
}

// Publish 同时投 per-stream channel + per-stream Streams buf + account channel + account buf.
//
// 3A 返修 #1: account-level 通道按 (tenant, account) 分区; tenantID == 0 视为编程错误
// → 跳过账号级 publish, 仅 per-stream (避免静默串台).
//
// Streams ID 由 Redis XADD 自动生成 (* 字面量); 我们 XADD 到 account buf 拿到 ID 后,
// 把它放进发布给 account channel 的 payload (作为 event_id 字段), 这样订阅方拿到的
// pub/sub message 自带 ID, 与 buffer 回放对齐.
func (f *RedisFanout) Publish(ctx context.Context, streamID string, accountID, tenantID int64, ev StreamEvent) error {
	evJSON, err := json.Marshal(ev)
	if err != nil {
		return fmt.Errorf("fanout: marshal stream event: %w", err)
	}

	// per-stream: 同时投到 buf + pub/sub.
	if streamID != "" {
		pipe := f.rdb.Pipeline()
		bufKey := streamBufKey(streamID)
		pipe.XAdd(ctx, &redis.XAddArgs{
			Stream: bufKey,
			MaxLen: perStreamBufMaxLen,
			Approx: true,
			Values: map[string]any{"data": string(evJSON)},
		})
		pipe.Expire(ctx, bufKey, streamBufTTL)
		pipe.Publish(ctx, streamPubChan(streamID), string(evJSON))
		if _, err := pipe.Exec(ctx); err != nil {
			return fmt.Errorf("fanout: publish per-stream: %w", err)
		}
	}

	// account-level: 必须 tenant+account 都非零; 缺 tenant → 静默跳过 + warn (caller 应当
	// 已经传 tenant, 缺 tenant 是编程错误, 不阻塞业务但要被注意到).
	if accountID == 0 || tenantID == 0 {
		if accountID != 0 && tenantID == 0 {
			f.logger.Warn(ctx, "fanout: account publish skipped (missing tenant_id)",
				"account_id", accountID, "stream_id", streamID)
		}
		return nil
	}
	bufKey := accountBufKey(tenantID, accountID)
	id, err := f.rdb.XAdd(ctx, &redis.XAddArgs{
		Stream: bufKey,
		MaxLen: accountBufMaxLen,
		Approx: true,
		Values: map[string]any{"data": string(evJSON)},
	}).Result()
	if err != nil {
		return fmt.Errorf("fanout: xadd account buf: %w", err)
	}
	// 显式 EXPIRE bufKey, 避免长期不活跃账号也占空间.
	_ = f.rdb.Expire(ctx, bufKey, accountBufTTL).Err()

	envelope := AccountEvent{EventID: id, Payload: evJSON}
	envJSON, err := json.Marshal(envelope)
	if err != nil {
		return fmt.Errorf("fanout: marshal account envelope: %w", err)
	}
	if err := f.rdb.Publish(ctx, accountPubChan(tenantID, accountID), string(envJSON)).Err(); err != nil {
		return fmt.Errorf("fanout: publish account: %w", err)
	}
	return nil
}

// Subscribe per-stream (legacy 兼容). 先 XRANGE 回放再 SUBSCRIBE 增量.
//
// 实现顺序:
//  1. SUBSCRIBE chat:stream:<id> (live, 异步缓冲)
//  2. XRANGE chat:stream:<id>:buf - + (replay)
//  3. drain live buffer, 用 (event content) dedup —— 由于 per-stream 没有稳定 ID,
//     这里采用 "replay 完成后立刻切到 live", 接受极少量重复 (legacy 端点, 客户端可幂等渲染).
func (f *RedisFanout) Subscribe(ctx context.Context, streamID string) (<-chan StreamEvent, func(), error) {
	// 先校验 stream 存在 (HEXISTS owner meta).
	exists, err := f.rdb.Exists(ctx, streamMetaKey(streamID)).Result()
	if err != nil {
		return nil, nil, fmt.Errorf("fanout: subscribe exists check: %w", err)
	}
	if exists == 0 {
		return nil, nil, errors.New("fanout: stream not found")
	}

	pubsub := f.rdb.Subscribe(ctx, streamPubChan(streamID))
	// 等握手就绪, 防止 SUBSCRIBE 还没生效就回放, 漏掉中间事件.
	if _, err := pubsub.Receive(ctx); err != nil {
		_ = pubsub.Close()
		return nil, nil, fmt.Errorf("fanout: subscribe handshake: %w", err)
	}

	out := make(chan StreamEvent, chSubBuffer)
	livech := pubsub.Channel(redis.WithChannelSize(chSubBuffer))

	done := make(chan struct{})
	go func() {
		defer close(out)
		// 1) XRANGE 回放 (best-effort).
		entries, rerr := f.rdb.XRange(ctx, streamBufKey(streamID), "-", "+").Result()
		if rerr != nil && !errors.Is(rerr, redis.Nil) {
			f.logger.Warn(ctx, "fanout: per-stream xrange replay failed",
				"stream_id", streamID, "err", rerr)
		}
		for _, en := range entries {
			ev, perr := parseEntryStreamEvent(en.Values)
			if perr != nil {
				continue
			}
			select {
			case out <- ev:
			case <-done:
				return
			}
		}
		// 2) 切 live.
		for {
			select {
			case <-done:
				return
			case msg, ok := <-livech:
				if !ok {
					return
				}
				var ev StreamEvent
				if err := json.Unmarshal([]byte(msg.Payload), &ev); err != nil {
					continue
				}
				select {
				case out <- ev:
				case <-done:
					return
				}
			}
		}
	}()

	cancel := func() {
		close(done)
		_ = pubsub.Close()
	}
	return out, cancel, nil
}

// Close per-stream: 不显式删 buffer / meta (留 TTL 自然过期, 让晚到的订阅仍能 replay).
// 仅写一个标记 (HSET closed=1) 便于 owner 信息更新; 实际 Subscribe 时不依赖 closed 标记.
func (f *RedisFanout) Close(ctx context.Context, streamID string) {
	if err := f.rdb.HSet(ctx, streamMetaKey(streamID), "closed", 1).Err(); err != nil {
		f.logger.Warn(ctx, "fanout: close hset failed", "stream_id", streamID, "err", err)
	}
}

// SubscribeAccount 账号级 SSE (T3.2 + T3.3 + 3A 返修 #1 tenant-scope).
//
// 实现顺序:
//  1. SUBSCRIBE tenant:<t>:account:<a>:events (异步 buffer live).
//  2. 如果 lastEventID != "":
//     a. XRANGE tenant:<t>:account:<a>:events_buf (lastEventID+1) → +∞: 回放
//     b. 命中失败 (XLEN=0 或 first id > lastEventID 等) → gap=true 返回, 不回放
//  3. drain live, 丢弃 EventID <= 已 replay 最大 ID 的, 之后逐个转发到 out.
//
// 注意: 这里 lastEventID 的"在 buffer 内"判定是 strict: 必须能 XRANGE 到 lastEventID
// 自身; 否则视为已被 TRIM, 报 gap. Redis Streams 没有"包含某 ID 但已 TRIM"的精确表示;
// 我们用 XRANGE [lastEventID, lastEventID] 探针.
func (f *RedisFanout) SubscribeAccount(ctx context.Context, accountID, tenantID int64, lastEventID string) (<-chan AccountEvent, func(), bool, error) {
	if accountID == 0 || tenantID == 0 {
		return nil, nil, false, errors.New("fanout: account_id and tenant_id required")
	}

	pubsub := f.rdb.Subscribe(ctx, accountPubChan(tenantID, accountID))
	if _, err := pubsub.Receive(ctx); err != nil {
		_ = pubsub.Close()
		return nil, nil, false, fmt.Errorf("fanout: subscribe account handshake: %w", err)
	}

	gap := false
	var replayed []AccountEvent
	if lastEventID != "" {
		probe, err := f.rdb.XRange(ctx, accountBufKey(tenantID, accountID), lastEventID, lastEventID).Result()
		if err != nil && !errors.Is(err, redis.Nil) {
			_ = pubsub.Close()
			return nil, nil, false, fmt.Errorf("fanout: probe last_event_id: %w", err)
		}
		if len(probe) == 0 {
			// lastEventID 已不在 buffer.
			gap = true
		} else {
			// XRANGE 从 lastEventID exclusive 拉到 +∞ (用 ( 前缀做 exclusive).
			entries, err := f.rdb.XRangeN(ctx, accountBufKey(tenantID, accountID), "("+lastEventID, "+", accountBufMaxLen).Result()
			if err != nil && !errors.Is(err, redis.Nil) {
				_ = pubsub.Close()
				return nil, nil, false, fmt.Errorf("fanout: replay account buf: %w", err)
			}
			for _, en := range entries {
				data, ok := en.Values["data"].(string)
				if !ok {
					continue
				}
				replayed = append(replayed, AccountEvent{EventID: en.ID, Payload: json.RawMessage(data)})
			}
		}
	}

	out := make(chan AccountEvent, chSubBuffer)
	livech := pubsub.Channel(redis.WithChannelSize(chSubBuffer))
	done := make(chan struct{})

	go func() {
		defer close(out)
		// 投放 replay.
		var lastReplayedID string
		for _, ev := range replayed {
			select {
			case out <- ev:
				lastReplayedID = ev.EventID
			case <-done:
				return
			}
		}
		// drain live, 丢弃 EventID <= lastReplayedID 的 (避免回放重复).
		for {
			select {
			case <-done:
				return
			case msg, ok := <-livech:
				if !ok {
					return
				}
				var env AccountEvent
				if err := json.Unmarshal([]byte(msg.Payload), &env); err != nil {
					continue
				}
				if lastReplayedID != "" && compareStreamID(env.EventID, lastReplayedID) <= 0 {
					continue
				}
				select {
				case out <- env:
				case <-done:
					return
				}
			}
		}
	}()

	cancel := func() {
		close(done)
		_ = pubsub.Close()
	}
	return out, cancel, gap, nil
}

// compareStreamID 比较两个 Redis Streams ID (ms-seq); 形如 "1715900400000-0".
// 返回 -1/0/1.
func compareStreamID(a, b string) int {
	if a == b {
		return 0
	}
	pa := strings.SplitN(a, "-", 2)
	pb := strings.SplitN(b, "-", 2)
	if len(pa) != 2 || len(pb) != 2 {
		// 退化为字符串比较, 同样单调.
		if a < b {
			return -1
		}
		return 1
	}
	var amA, amB, asA, asB int64
	_, _ = fmt.Sscanf(pa[0], "%d", &amA)
	_, _ = fmt.Sscanf(pb[0], "%d", &amB)
	_, _ = fmt.Sscanf(pa[1], "%d", &asA)
	_, _ = fmt.Sscanf(pb[1], "%d", &asB)
	switch {
	case amA < amB:
		return -1
	case amA > amB:
		return 1
	case asA < asB:
		return -1
	case asA > asB:
		return 1
	}
	return 0
}

// RegisterConnection ZADD + SET owner (按 tenant+account 分区).
func (f *RedisFanout) RegisterConnection(ctx context.Context, accountID, tenantID int64, connID, nodeID string, ts time.Time) error {
	pipe := f.rdb.TxPipeline()
	zkey := accountConnsZSetKey(tenantID, accountID)
	pipe.ZAdd(ctx, zkey, redis.Z{Score: float64(ts.UnixMilli()), Member: connID})
	pipe.Expire(ctx, zkey, connOwnerTTL)
	pipe.Set(ctx, accountConnOwnerKey(tenantID, accountID, connID), nodeID, connOwnerTTL)
	if _, err := pipe.Exec(ctx); err != nil {
		return fmt.Errorf("fanout: register conn: %w", err)
	}
	return nil
}

// RefreshConnection 重置 ZSET key + owner key 的 EXPIRE (3A 返修 #2).
//
// 不重写 score (避免 RefreshConnection 把 "最旧" 变 "最新"); 仅刷 TTL. owner key
// 用 EXPIRE (key 必须存在; 若已过期 EXPIRE 返回 false, 不报错继续).
func (f *RedisFanout) RefreshConnection(ctx context.Context, accountID, tenantID int64, connID string) error {
	pipe := f.rdb.Pipeline()
	pipe.Expire(ctx, accountConnsZSetKey(tenantID, accountID), connOwnerTTL)
	pipe.Expire(ctx, accountConnOwnerKey(tenantID, accountID, connID), connOwnerTTL)
	if _, err := pipe.Exec(ctx); err != nil {
		return fmt.Errorf("fanout: refresh conn: %w", err)
	}
	return nil
}

func (f *RedisFanout) RemoveConnection(ctx context.Context, accountID, tenantID int64, connID string) error {
	pipe := f.rdb.TxPipeline()
	pipe.ZRem(ctx, accountConnsZSetKey(tenantID, accountID), connID)
	pipe.Del(ctx, accountConnOwnerKey(tenantID, accountID, connID))
	if _, err := pipe.Exec(ctx); err != nil {
		return fmt.Errorf("fanout: remove conn: %w", err)
	}
	return nil
}

func (f *RedisFanout) CountConnections(ctx context.Context, accountID, tenantID int64) (int64, error) {
	n, err := f.rdb.ZCard(ctx, accountConnsZSetKey(tenantID, accountID)).Result()
	if err != nil {
		return 0, fmt.Errorf("fanout: zcard conns: %w", err)
	}
	return n, nil
}

func (f *RedisFanout) OldestConnection(ctx context.Context, accountID, tenantID int64) (string, string, bool, error) {
	members, err := f.rdb.ZRangeWithScores(ctx, accountConnsZSetKey(tenantID, accountID), 0, 0).Result()
	if err != nil {
		return "", "", false, fmt.Errorf("fanout: zrange oldest: %w", err)
	}
	if len(members) == 0 {
		return "", "", false, nil
	}
	connID, _ := members[0].Member.(string)
	owner, err := f.rdb.Get(ctx, accountConnOwnerKey(tenantID, accountID, connID)).Result()
	if err != nil && !errors.Is(err, redis.Nil) {
		return "", "", false, fmt.Errorf("fanout: owner get: %w", err)
	}
	return connID, owner, true, nil
}

// PublishKick 通过 bus:cmd:kick:<ownerNodeID> 通知 owner 节点关掉某连接.
//
// 3A 返修 #3: 调用方不可以预删 ZSET; 仅当 PUBLISH 成功才能"指望"对端去 deregister.
// 失败时 ZSET 仍保留, 下一次 register 超限会再算"最旧 conn"并重试.
//
// PUBLISH 命令本身不区分"有没有订阅者", 不能用它检测 owner 是否真的在听. 我们仅
// 在 Redis 网络异常 / PUBSUB 协议错误时返回 error.
func (f *RedisFanout) PublishKick(ctx context.Context, accountID, tenantID int64, connID, ownerNodeID string) error {
	cmd := KickCommand{
		AccountID: accountID,
		TenantID:  tenantID,
		ConnID:    connID,
		Reason:    "max_devices",
	}
	body, err := json.Marshal(cmd)
	if err != nil {
		return fmt.Errorf("fanout: marshal kick: %w", err)
	}
	if err := f.rdb.Publish(ctx, kickChanKey(ownerNodeID), string(body)).Err(); err != nil {
		return fmt.Errorf("fanout: publish kick: %w", err)
	}
	return nil
}

func (f *RedisFanout) SubscribeKick(ctx context.Context, selfNodeID string) (<-chan KickCommand, func(), error) {
	if selfNodeID == "" {
		return nil, nil, errors.New("fanout: node_id required")
	}
	pubsub := f.rdb.Subscribe(ctx, kickChanKey(selfNodeID))
	if _, err := pubsub.Receive(ctx); err != nil {
		_ = pubsub.Close()
		return nil, nil, fmt.Errorf("fanout: subscribe kick handshake: %w", err)
	}
	out := make(chan KickCommand, chSubBuffer)
	livech := pubsub.Channel(redis.WithChannelSize(chSubBuffer))
	done := make(chan struct{})
	go func() {
		defer close(out)
		for {
			select {
			case <-done:
				return
			case msg, ok := <-livech:
				if !ok {
					return
				}
				var cmd KickCommand
				if err := json.Unmarshal([]byte(msg.Payload), &cmd); err != nil {
					continue
				}
				select {
				case out <- cmd:
				case <-done:
					return
				}
			}
		}
	}()
	cancel := func() {
		close(done)
		_ = pubsub.Close()
	}
	return out, cancel, nil
}

// PublishCancel (Batch 3B T3.5 + 返修 #3) 通过 bus:cmd:cancel:<ownerNodeID> 通知 owner 节点
// 取消某 streamID. 返回 PUBLISH 的 subscriber 数; 0 表示对端节点不在线 → caller 走 fallback.
//
// PUBLISH 返回的 integer = "已收到该消息的订阅者数"; 在 Redis Cluster + sharded pub/sub
// 模式下可能不准, 但 chat fanout 走全局 pub/sub channel, 返回值可信.
func (f *RedisFanout) PublishCancel(ctx context.Context, ownerNodeID string, cmd CancelCommand) (int64, error) {
	if ownerNodeID == "" {
		return 0, errors.New("fanout: owner node_id required")
	}
	body, err := json.Marshal(cmd)
	if err != nil {
		return 0, fmt.Errorf("fanout: marshal cancel: %w", err)
	}
	n, err := f.rdb.Publish(ctx, cancelChanKey(ownerNodeID), string(body)).Result()
	if err != nil {
		return 0, fmt.Errorf("fanout: publish cancel: %w", err)
	}
	return n, nil
}

// SubscribeCancel (Batch 3B T3.5) 节点启动时调用; 持有单连接订阅 bus:cmd:cancel:<self>.
//
// 实现与 SubscribeKick 等价 (单 channel / 单 pubsub / done 关闭即 UNSUBSCRIBE).
// chat.Service 启动后台 goroutine 消费, 收到 CancelCommand 后在本节点查 in-process
// per-stream cancel func 并触发.
func (f *RedisFanout) SubscribeCancel(ctx context.Context, selfNodeID string) (<-chan CancelCommand, func(), error) {
	if selfNodeID == "" {
		return nil, nil, errors.New("fanout: node_id required")
	}
	pubsub := f.rdb.Subscribe(ctx, cancelChanKey(selfNodeID))
	if _, err := pubsub.Receive(ctx); err != nil {
		_ = pubsub.Close()
		return nil, nil, fmt.Errorf("fanout: subscribe cancel handshake: %w", err)
	}
	out := make(chan CancelCommand, chSubBuffer)
	livech := pubsub.Channel(redis.WithChannelSize(chSubBuffer))
	done := make(chan struct{})
	go func() {
		defer close(out)
		for {
			select {
			case <-done:
				return
			case msg, ok := <-livech:
				if !ok {
					return
				}
				var cmd CancelCommand
				if err := json.Unmarshal([]byte(msg.Payload), &cmd); err != nil {
					continue
				}
				select {
				case out <- cmd:
				case <-done:
					return
				}
			}
		}
	}()
	cancel := func() {
		close(done)
		_ = pubsub.Close()
	}
	return out, cancel, nil
}

// parseEntryStreamEvent 从 XStream entry.Values["data"] 解出 StreamEvent.
func parseEntryStreamEvent(values map[string]any) (StreamEvent, error) {
	raw, ok := values["data"].(string)
	if !ok {
		return StreamEvent{}, errors.New("missing data field")
	}
	var ev StreamEvent
	if err := json.Unmarshal([]byte(raw), &ev); err != nil {
		return StreamEvent{}, err
	}
	return ev, nil
}

// 显式 sentinel 引用, 避免 go vet 把 errAccountEventNotInBuf 标为未用.
var _ = errAccountEventNotInBuf

// ----- 编译期断言 -----
var _ Fanout = (*LocalFanout)(nil)
var _ Fanout = (*RedisFanout)(nil)
