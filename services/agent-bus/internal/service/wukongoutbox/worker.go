// Package wukongoutbox 是 ADR-0026 P0 前置 — WuKong-send outbox 的异步发送 worker + enqueue service。
//
// 设计:
//   - Run 单 worker ticker 循环(默认 5s)→ ClaimDue(batch) → 逐条 SendMessage → MarkSent/MarkRetry/MarkFailed。
//   - 多 worker 实例并发安全(repo.ClaimDue 用 FOR UPDATE SKIP LOCKED)。
//   - capped backoff(domain.BackoffDelay);超 max_retries → 终态 failed(不静默吞)。
//   - 一条 send 失败不阻塞同批其它;每条 send 有超时;响应 ctx cancel 退出。
//
// 本轮(方案 A)只建基础设施 + worker,不切任何现有发送流量;EnqueueWuKongMessage 供下一轮
// agent-direct / revoke / 群代发接入。契约见 docs/contracts/agent-bus-client-contract.md §P2.1b。
package wukongoutbox

import (
	"context"
	"log"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/wukongoutbox"
)

// Sender 把一条消息发进 WuKong。*internal/im/wukong.Client 直接满足(签名一致)。
type Sender interface {
	SendMessage(ctx context.Context, fromUID, channelID string, channelType int, payload []byte) (int64, error)
}

// WorkerOptions 控制 worker 行为。
type WorkerOptions struct {
	Interval    time.Duration    // 每轮 poll 间隔;默认 5s
	Batch       int              // 每轮 claim 条数;默认 20
	SendTimeout time.Duration    // 单条 SendMessage 超时(防 hang 阻塞整批);默认 15s
	WorkerID    string           // 持租标识(诊断用);默认 "wukong-send-outbox"
	Lease       time.Duration    // sending 租约时长,**须 > SendTimeout**;默认 2min(dom.DefaultLease)
	Logger      *log.Logger      // 默认 log.Default()
	Now         func() time.Time // 测试可注入;默认 time.Now
}

func (o WorkerOptions) interval() time.Duration {
	if o.Interval <= 0 {
		return 5 * time.Second
	}
	return o.Interval
}

func (o WorkerOptions) batch() int {
	if o.Batch <= 0 {
		return 20
	}
	return o.Batch
}

func (o WorkerOptions) sendTimeout() time.Duration {
	if o.SendTimeout <= 0 {
		return 15 * time.Second
	}
	return o.SendTimeout
}

func (o WorkerOptions) workerID() string {
	if o.WorkerID == "" {
		return "wukong-send-outbox"
	}
	return o.WorkerID
}

func (o WorkerOptions) lease() time.Duration {
	if o.Lease <= 0 {
		return dom.DefaultLease
	}
	return o.Lease
}

func (o WorkerOptions) logger() *log.Logger {
	if o.Logger == nil {
		return log.Default()
	}
	return o.Logger
}

func (o WorkerOptions) now() time.Time {
	if o.Now == nil {
		return time.Now()
	}
	return o.Now()
}

// Run 阻塞循环;ctx 取消时退出。
func Run(ctx context.Context, repo dom.Repository, sender Sender, opts WorkerOptions) {
	lg := opts.logger()
	lg.Printf("wukong_send_outbox.worker started interval=%s batch=%d", opts.interval(), opts.batch())
	ticker := time.NewTicker(opts.interval())
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			lg.Printf("wukong_send_outbox.worker stopped")
			return
		case <-ticker.C:
			ProcessBatch(ctx, repo, sender, opts)
		}
	}
}

// ProcessBatch claim 一批并逐条发送;导出供窄测同步驱动。返回本轮处理条数。
func ProcessBatch(ctx context.Context, repo dom.Repository, sender Sender, opts WorkerOptions) int {
	lg := opts.logger()
	claimCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	msgs, err := repo.ClaimDue(claimCtx, opts.workerID(), opts.lease(), opts.batch(), opts.now())
	cancel()
	if err != nil {
		lg.Printf("wukong_send_outbox.claim error: %v", err)
		return 0
	}
	for i := range msgs {
		// 逐条独立处理:一条失败(标记 retry/failed)不影响下一条。
		processOne(ctx, repo, sender, opts, msgs[i])
	}
	return len(msgs)
}

func processOne(ctx context.Context, repo dom.Repository, sender Sender, opts WorkerOptions, m dom.Message) {
	lg := opts.logger()
	sendCtx, cancel := context.WithTimeout(ctx, opts.sendTimeout())
	_, err := sender.SendMessage(sendCtx, m.FromUID, m.ChannelID, m.ChannelType, m.Payload)
	cancel()

	if err == nil {
		if merr := markSentWithRetry(ctx, repo, m, opts); merr != nil {
			// 消息已经真实发进 WuKong，但标记失败：这条记录会在 lease 到期后被
			// ClaimDue 当作"没发成功"重新认领、重新调 SendMessage —— 造成同一条
			// 通话卡片/消息在 WuKong 里出现多条（每次都是新 messageID，dedup_key
			// 层面查不出来，retry_count 也不会变，因为它只在发送失败分支才 +1）。
			// 这里已经原地重试过，仍失败才走到这条日志，需要人工介入排查。
			lg.Printf("wukong_send_outbox.markSent error (after retries) id=%s dedup=%s: %v", m.ID, m.DedupKey, merr)
		}
		return
	}

	maxRetries := m.MaxRetries
	if maxRetries <= 0 {
		maxRetries = dom.DefaultMaxRetries
	}
	attempt := m.RetryCount + 1
	lg.Printf("wukong_send_outbox.send failed tenant=%s channel=%s source=%s dedup=%s retry=%d/%d: %v",
		m.TenantID, m.ChannelID, m.Source, m.DedupKey, m.RetryCount, maxRetries, err)

	if attempt >= maxRetries {
		if ferr := repo.MarkFailed(ctx, m.ID, err.Error()); ferr != nil {
			lg.Printf("wukong_send_outbox.markFailed error id=%s dedup=%s: %v", m.ID, m.DedupKey, ferr)
			return
		}
		lg.Printf("wukong_send_outbox.failed (>= %d retries, 不再重试) tenant=%s dedup=%s",
			maxRetries, m.TenantID, m.DedupKey)
		return
	}
	next := opts.now().Add(dom.BackoffDelay(attempt))
	if rerr := repo.MarkRetry(ctx, m.ID, err.Error(), next); rerr != nil {
		lg.Printf("wukong_send_outbox.markRetry error id=%s dedup=%s: %v", m.ID, m.DedupKey, rerr)
	}
}

// markSentWithRetry 在 SendMessage 已经成功之后原地重试 MarkSent。
//
// MarkSent 只是一条本地 Postgres UPDATE，正常情况下几乎不会持续失败；单次失败大概率是
// 瞬时抖动。这里不重试的代价是：这条记录会一直卡在 status='sending'，lease 到期后
// ClaimDue 把它当"没发成功"重新认领、重新调 SendMessage —— 造成同一条消息被真实重发给
// WuKong（每次都是新 messageID），最终用户端看到重复消息。三次短间隔重试足以覆盖绝大多数
// 瞬时故障；仍失败则只能记日志人工介入，不在这里无限重试阻塞 worker。
func markSentWithRetry(ctx context.Context, repo dom.Repository, m dom.Message, opts WorkerOptions) error {
	const maxAttempts = 3
	backoff := []time.Duration{0, 200 * time.Millisecond, 500 * time.Millisecond}
	var lastErr error
	for i := 0; i < maxAttempts; i++ {
		if backoff[i] > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(backoff[i]):
			}
		}
		if lastErr = repo.MarkSent(ctx, m.ID, opts.now()); lastErr == nil {
			return nil
		}
	}
	return lastErr
}
