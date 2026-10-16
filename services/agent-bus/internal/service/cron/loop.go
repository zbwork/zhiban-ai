// loop.go — Bus 进程内的 cron worker loop (M9 Phase A).
//
// 由 cmd/bus 在 startup 期间起 1 个 goroutine 调 RunLoop; ctx cancel 即退出.
// 多 bus 副本均运行此 loop, 通过 cron_dispatch_locks 互斥保证单触发.
package cron

import (
	"context"
	"time"
)

// Loop 封装一个可以反复 tick 的 cron worker.
type Loop struct {
	Service  Service
	Interval time.Duration
}

// NewLoop 构造; Service / Interval 必须非零.
func NewLoop(svc Service, interval time.Duration) *Loop {
	if interval <= 0 {
		interval = DefaultDispatchInterval
	}
	return &Loop{Service: svc, Interval: interval}
}

// Run 阻塞跑直到 ctx 取消. 一次 tick = DispatchTick + ProcessQueuedRuns.
func (l *Loop) Run(ctx context.Context) {
	if l == nil || l.Service == nil {
		return
	}
	t := time.NewTicker(l.Interval)
	defer t.Stop()
	// 启动后立即跑一次 (避免冷启等 30s).
	l.tickOnce(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			l.tickOnce(ctx)
		}
	}
}

func (l *Loop) tickOnce(ctx context.Context) {
	// Codex P1#3: 先 reap stale running runs (executor 崩溃后未清理的 row), 否则
	// concurrent_policy=forbid 的任务会因 HasActiveRun 永真而永久跳过.
	_, _ = l.Service.ReapStaleRuns(ctx)
	_, _ = l.Service.DispatchTick(ctx)
	_, _ = l.Service.ProcessQueuedRuns(ctx)
}
