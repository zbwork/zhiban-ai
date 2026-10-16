package wukongwh

import (
	"context"
	"sync"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/mobilepush"
)

// notificationDebounceWindow: 同一 (tenant, account, conversation) 在这个窗口内的
// 多条 chat_message 通知合并成一条,取最新内容——2026-08-10 用户反馈实测确认:
// 有的 agent(如"FAST 财税助手")一轮回复会真发出 2 条独立 WuKong 消息(不是假失败
// 重发,是 agent 自己的行为),每条都会各自触发一条推送,短时间内连收 2 条通知。
//
// 已知限制: 纯进程内防抖,多副本部署时如果两条消息的 webhook 落到不同 bus pod,
// 防抖窗口不会跨副本生效(退化为不合并,不是错误行为,只是没达到合并效果)。
const notificationDebounceWindow = 3 * time.Second

type pendingNotification struct {
	ctx    context.Context
	in     dom.EnqueueInput
	timer  *time.Timer
	cancel context.CancelFunc
}

// notificationDebouncer 把同一 key 在 window 内的多次 schedule 合并成一次
// enqueue(取最后一次的内容)。window<=0 时不防抖,同步立即 enqueue(单测/兼容用)。
type notificationDebouncer struct {
	mu      sync.Mutex
	pending map[string]*pendingNotification
	enqueue NotificationEnqueuer
	window  time.Duration
}

func newNotificationDebouncer(enqueue NotificationEnqueuer, window time.Duration) *notificationDebouncer {
	return &notificationDebouncer{pending: make(map[string]*pendingNotification), enqueue: enqueue, window: window}
}

func (d *notificationDebouncer) schedule(ctx context.Context, key string, in dom.EnqueueInput) {
	if d.window <= 0 {
		_, _ = d.enqueue.Enqueue(ctx, in)
		return
	}
	// 用 WithoutCancel 保留 trace/tenant 等透传值,但不继承原请求的取消——
	// 定时器触发时原 webhook 请求早已处理完,不能让它的 ctx 提前把这次 enqueue 取消掉。
	deferredCtx, cancel := context.WithCancel(context.WithoutCancel(ctx))

	d.mu.Lock()
	defer d.mu.Unlock()
	if p, ok := d.pending[key]; ok {
		p.timer.Stop()
		p.cancel() // 旧的 deferredCtx 不再需要,释放
		p.ctx = deferredCtx
		p.cancel = cancel
		p.in = in
		p.timer = time.AfterFunc(d.window, func() { d.fire(key) })
		return
	}
	d.pending[key] = &pendingNotification{
		ctx:    deferredCtx,
		in:     in,
		cancel: cancel,
		timer:  time.AfterFunc(d.window, func() { d.fire(key) }),
	}
}

func (d *notificationDebouncer) fire(key string) {
	d.mu.Lock()
	p, ok := d.pending[key]
	if ok {
		delete(d.pending, key)
	}
	d.mu.Unlock()
	if !ok {
		return
	}
	defer p.cancel()
	ctx, cancel := context.WithTimeout(p.ctx, 15*time.Second)
	defer cancel()
	_, _ = d.enqueue.Enqueue(ctx, p.in)
}
