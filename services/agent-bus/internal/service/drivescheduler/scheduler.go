// Package drivescheduler runs shared drive jobs with database locks and trigger leases.
package drivescheduler

import (
	"context"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	drivev3repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
	svcdriv3 "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
	"sync"
	"time"
)

// RunJob 启动一个周期性 ticker, 调 fn 直到 ctx done. fn 内部不要 panic; 失败应吞下并 log.
// startup jitter: 不同 job 错开 0-30s 启动, 避免同时压 DB.
func RunJob(
	ctx context.Context,
	wg *sync.WaitGroup,
	logger *logpkg.Logger,
	worker *svcdriv3.WorkerSvc,
	repo *drivev3repo.WorkerJobRepo,
	name string,
	interval time.Duration,
	mu *sync.Mutex,
	fn func(context.Context) (svcdriv3.WorkerRunStats, error),
) {
	defer wg.Done()
	// 启动时随便等一点 (用 hash(name) 模 30s 做确定性 jitter, 避免依赖 rand)
	startupJitter := time.Duration(len(name)*3) * time.Second
	select {
	case <-ctx.Done():
		return
	case <-time.After(startupJitter):
	}
	// 启动后立刻跑一次 (省 1 个 interval 周期)
	RunOnce(ctx, logger, worker, repo, name, mu, fn)
	tick := time.NewTicker(interval)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			logger.Info(ctx, "drive.worker.job_stopped", "job", name)
			return
		case <-tick.C:
			RunOnce(ctx, logger, worker, repo, name, mu, fn)
		}
	}
}

// RunOnce 跑一轮 job. 返回是否真的执行了 (集群锁被其它副本持有或 DB 不可用时跳过, 返回 false).
// 同 job 互斥统一在这里收口: 进程内 per-job mutex + 跨副本 pg advisory lock,
// 周期调度与手动触发两条路径都经过本函数, 不存在旁路.
func RunOnce(
	ctx context.Context,
	logger *logpkg.Logger,
	worker *svcdriv3.WorkerSvc,
	repo *drivev3repo.WorkerJobRepo,
	name string,
	mu *sync.Mutex,
	fn func(context.Context) (svcdriv3.WorkerRunStats, error),
) (ran bool) {
	// 进程内: 周期调度与手动触发共用锁, 同 job 串行执行 (batch 幂等, 迟到方跑下一轮无害).
	mu.Lock()
	defer mu.Unlock()
	// 跨副本: pg_try_advisory_lock; 拿不到说明其它副本正在跑同一 job, 本轮跳过.
	lock, got, err := repo.TryLockJob(ctx, name)
	if err != nil {
		logger.Warn(ctx, "drive.worker.job_lock_failed", "job", name, "err", err.Error())
		return false
	}
	if !got {
		logger.Info(ctx, "drive.worker.job_lock_busy", "job", name)
		return false
	}
	defer lock.Release(ctx)

	started := time.Now()
	if err := worker.MarkWorkerJobStarted(ctx, name, started); err != nil {
		logger.Warn(ctx, "drive.worker.status_start_failed", "job", name, "err", err.Error())
	}
	stats, err := fn(ctx)
	finished := time.Now()
	if markErr := worker.MarkWorkerJobFinished(ctx, name, started, finished, stats, err); markErr != nil {
		logger.Warn(ctx, "drive.worker.status_finish_failed", "job", name, "err", markErr.Error())
	}
	return true
}

// RunTriggerPoller 每 10s 认领手动触发请求 (drive_worker_job_triggers, F06 §4.7 2026-07-06 增补).
// 租约语义 (2026-07-07 review 修复): 认领只延 lock_until, 真跑完才 CompleteTrigger 标 consumed;
// 认领后崩溃 → 租约到期被任意副本重捡, 触发不丢失. 本轮没跑成 (集群锁被占等) 则 ReleaseTrigger
// 提前释放租约, 下轮 poll 立即重试.
func RunTriggerPoller(
	ctx context.Context,
	wg *sync.WaitGroup,
	logger *logpkg.Logger,
	worker *svcdriv3.WorkerSvc,
	repo *drivev3repo.WorkerJobRepo,
	jobFns map[string]func(context.Context) (svcdriv3.WorkerRunStats, error),
	locks map[string]*sync.Mutex,
) {
	defer wg.Done()
	tick := time.NewTicker(10 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			logger.Info(ctx, "drive.worker.trigger_poller_stopped")
			return
		case <-tick.C:
			claims, err := repo.ClaimDueTriggers(ctx)
			if err != nil {
				logger.Warn(ctx, "drive.worker.trigger_claim_failed", "err", err.Error())
				continue
			}
			for _, c := range claims {
				fn, ok := jobFns[c.Job]
				if !ok {
					// CHECK 约束下不应出现; 防毒丸: 标完成避免租约到期后无限重捡.
					logger.Warn(ctx, "drive.worker.trigger_unknown_job", "job", c.Job, "id", c.ID)
					completed, err := repo.CompleteTrigger(ctx, c.ID, c.LockUntil)
					if err != nil {
						logger.Warn(ctx, "drive.worker.trigger_complete_failed", "job", c.Job, "id", c.ID, "err", err.Error())
					} else if !completed {
						logger.Warn(ctx, "drive.worker.trigger_complete_stale", "job", c.Job, "id", c.ID)
					}
					continue
				}
				logger.Info(ctx, "drive.worker.trigger_claimed", "job", c.Job, "id", c.ID)
				if RunOnce(ctx, logger, worker, repo, c.Job, locks[c.Job], fn) {
					completed, err := repo.CompleteTrigger(ctx, c.ID, c.LockUntil)
					if err != nil {
						logger.Warn(ctx, "drive.worker.trigger_complete_failed", "job", c.Job, "id", c.ID, "err", err.Error())
					} else if !completed {
						logger.Warn(ctx, "drive.worker.trigger_complete_stale", "job", c.Job, "id", c.ID)
					}
				} else {
					logger.Info(ctx, "drive.worker.trigger_deferred", "job", c.Job, "id", c.ID)
					released, err := repo.ReleaseTrigger(ctx, c.ID, c.LockUntil)
					if err != nil {
						logger.Warn(ctx, "drive.worker.trigger_release_failed", "job", c.Job, "id", c.ID, "err", err.Error())
					} else if !released {
						logger.Warn(ctx, "drive.worker.trigger_release_stale", "job", c.Job, "id", c.ID)
					}
				}
			}
		}
	}
}
