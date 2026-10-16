// workerjob.go — F06 §4.7 2026-07-06 增补: drive_worker_job_failures 失败明细
// + drive_worker_job_triggers 手动触发队列的 PG 实现.
package drive

import (
	"context"
	"fmt"
	"hash/fnv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// WorkerJobRepo 失败明细 + 手动触发队列.
type WorkerJobRepo struct{ pool *pgxpool.Pool }

// NewWorkerJobRepo 构造.
func NewWorkerJobRepo(pool *pgxpool.Pool) *WorkerJobRepo { return &WorkerJobRepo{pool: pool} }

const (
	// failureRetention 失败明细保留窗口; InsertFailures 写入时顺带滚动清理.
	failureRetention = 14 * 24 * time.Hour
	// triggerRetention 已消费触发行保留窗口; EnqueueTrigger 入队时顺带滚动清理.
	triggerRetention = 30 * 24 * time.Hour
	// triggerLease 触发认领的执行租约; 超过未完成视为认领方崩溃, 允许任意副本重捡.
	// 取值须大于最慢一轮 job 的正常耗时 (batch 100, 通常秒级) 并留足余量.
	triggerLease = 15 * time.Minute
)

// truncateRunes 按字符截断 (VARCHAR(n) 以字符计).
func truncateRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

// InsertFailures 批量落一轮失败明细, 并顺带清理该 job 保留窗口外旧行.
// 调用方 (MarkWorkerJobFinished) 为 best-effort 语义: 失败仅记日志, 不影响 job 本身.
func (r *WorkerJobRepo) InsertFailures(ctx context.Context, job string, items []dom.WorkerJobFailure) error {
	if len(items) == 0 {
		return nil
	}
	batch := &pgx.Batch{}
	batch.Queue(`DELETE FROM drive_worker_job_failures WHERE job = $1 AND occurred_at < $2`,
		job, time.Now().Add(-failureRetention))
	for i := range items {
		f := &items[i]
		occurred := f.OccurredAt
		if occurred.IsZero() {
			occurred = time.Now()
		}
		batch.Queue(`
INSERT INTO drive_worker_job_failures (job, tenant_id, object_kind, object_ref, reason, occurred_at)
VALUES ($1, $2, $3, $4, $5, $6)`,
			job, f.TenantID, f.ObjectKind, truncateRunes(f.ObjectRef, 128), truncateRunes(f.Reason, 1000), occurred)
	}
	if err := r.pool.SendBatch(ctx, batch).Close(); err != nil {
		return fmt.Errorf("drive.WorkerJobRepo.InsertFailures: %w", err)
	}
	return nil
}

// ListFailures 按 occurred_at DESC 分页列某 job 的失败明细, 返回 (rows, total).
func (r *WorkerJobRepo) ListFailures(ctx context.Context, job string, limit, offset int) ([]dom.WorkerJobFailure, int64, error) {
	var total int64
	if err := r.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM drive_worker_job_failures WHERE job = $1`, job).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("drive.WorkerJobRepo.ListFailures.count: %w", err)
	}
	rows, err := r.pool.Query(ctx, `
SELECT id, job, tenant_id, object_kind, object_ref, reason, occurred_at
  FROM drive_worker_job_failures
 WHERE job = $1
 ORDER BY occurred_at DESC, id DESC
 LIMIT $2 OFFSET $3`, job, limit, offset)
	if err != nil {
		return nil, 0, fmt.Errorf("drive.WorkerJobRepo.ListFailures: %w", err)
	}
	defer rows.Close()
	var out []dom.WorkerJobFailure
	for rows.Next() {
		var f dom.WorkerJobFailure
		if err := rows.Scan(&f.ID, &f.Job, &f.TenantID, &f.ObjectKind, &f.ObjectRef, &f.Reason, &f.OccurredAt); err != nil {
			return nil, 0, fmt.Errorf("drive.WorkerJobRepo.ListFailures.scan: %w", err)
		}
		out = append(out, f)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, fmt.Errorf("drive.WorkerJobRepo.ListFailures.rows: %w", err)
	}
	return out, total, nil
}

// EnqueueTrigger 入队一条手动触发请求; 该 job 已有未消费请求时幂等 NOOP (queued=false).
// 幂等由部分唯一索引 uq_drive_worker_job_triggers_pending 兜底, 并发安全.
func (r *WorkerJobRepo) EnqueueTrigger(ctx context.Context, job string, requestedBy int64) (queued bool, err error) {
	if _, err := r.pool.Exec(ctx,
		`DELETE FROM drive_worker_job_triggers WHERE consumed_at IS NOT NULL AND consumed_at < $1`,
		time.Now().Add(-triggerRetention)); err != nil {
		return false, fmt.Errorf("drive.WorkerJobRepo.EnqueueTrigger.prune: %w", err)
	}
	tag, err := r.pool.Exec(ctx, `
INSERT INTO drive_worker_job_triggers (job, requested_by)
VALUES ($1, $2)
ON CONFLICT (job) WHERE consumed_at IS NULL DO NOTHING`, job, requestedBy)
	if err != nil {
		return false, fmt.Errorf("drive.WorkerJobRepo.EnqueueTrigger: %w", err)
	}
	return tag.RowsAffected() == 1, nil
}

// PendingTriggerJobs 返回当前存在未消费触发请求的 job 集合 (admin 看板 trigger_pending 用).
func (r *WorkerJobRepo) PendingTriggerJobs(ctx context.Context) (map[string]bool, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT job FROM drive_worker_job_triggers WHERE consumed_at IS NULL`)
	if err != nil {
		return nil, fmt.Errorf("drive.WorkerJobRepo.PendingTriggerJobs: %w", err)
	}
	defer rows.Close()
	out := make(map[string]bool)
	for rows.Next() {
		var job string
		if err := rows.Scan(&job); err != nil {
			return nil, fmt.Errorf("drive.WorkerJobRepo.PendingTriggerJobs.scan: %w", err)
		}
		out[job] = true
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("drive.WorkerJobRepo.PendingTriggerJobs.rows: %w", err)
	}
	return out, nil
}

// ClaimedTrigger 一次被认领的手动触发请求; 执行完成后须带 LockUntil
// 调 CompleteTrigger / ReleaseTrigger, 防旧认领覆盖新租约.
type ClaimedTrigger struct {
	ID        int64
	Job       string
	LockUntil time.Time
}

// ClaimDueTriggers 认领全部「未完成且无有效租约」的触发请求 (UPDATE...RETURNING, 多副本安全).
// 租约语义: 只设 lock_until, 不标 consumed_at —— 认领方崩溃后租约到期自动可被重捡, 触发不丢失.
// 部分唯一索引保证每 job 至多 1 行未完成, 故返回值天然每 job 至多 1 条.
func (r *WorkerJobRepo) ClaimDueTriggers(ctx context.Context) ([]ClaimedTrigger, error) {
	rows, err := r.pool.Query(ctx, `
UPDATE drive_worker_job_triggers
   SET lock_until = now() + make_interval(secs => $1)
 WHERE consumed_at IS NULL
   AND (lock_until IS NULL OR lock_until < now())
RETURNING id, job, lock_until`, triggerLease.Seconds())
	if err != nil {
		return nil, fmt.Errorf("drive.WorkerJobRepo.ClaimDueTriggers: %w", err)
	}
	defer rows.Close()
	var out []ClaimedTrigger
	for rows.Next() {
		var c ClaimedTrigger
		if err := rows.Scan(&c.ID, &c.Job, &c.LockUntil); err != nil {
			return nil, fmt.Errorf("drive.WorkerJobRepo.ClaimDueTriggers.scan: %w", err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("drive.WorkerJobRepo.ClaimDueTriggers.rows: %w", err)
	}
	return out, nil
}

// CompleteTrigger 标记一次手动触发已执行完成 (job 跑完即完成, 业务性部分失败也算; 仅崩溃留给租约重捡).
// 返回 false 表示这次认领已过期/被其它 worker 重捡, 调用方不应再认为自己完成了该触发行.
func (r *WorkerJobRepo) CompleteTrigger(ctx context.Context, id int64, lockUntil time.Time) (bool, error) {
	tag, err := r.pool.Exec(ctx, `
UPDATE drive_worker_job_triggers
   SET consumed_at = now()
 WHERE id = $1
   AND consumed_at IS NULL
   AND lock_until = $2`, id, lockUntil)
	if err != nil {
		return false, fmt.Errorf("drive.WorkerJobRepo.CompleteTrigger: %w", err)
	}
	return tag.RowsAffected() == 1, nil
}

// ReleaseTrigger 提前释放一次认领 (本轮没跑成, 如集群锁被其它副本占用), 让下轮 poll 立即可重捡.
// 返回 false 表示这次认领已过期/被其它 worker 重捡, 避免旧 worker 清掉新租约.
func (r *WorkerJobRepo) ReleaseTrigger(ctx context.Context, id int64, lockUntil time.Time) (bool, error) {
	tag, err := r.pool.Exec(ctx, `
UPDATE drive_worker_job_triggers
   SET lock_until = NULL
 WHERE id = $1
   AND consumed_at IS NULL
   AND lock_until = $2`, id, lockUntil)
	if err != nil {
		return false, fmt.Errorf("drive.WorkerJobRepo.ReleaseTrigger: %w", err)
	}
	return tag.RowsAffected() == 1, nil
}

// JobLock 一次 pg advisory lock 的持有句柄 (会话级, 绑定专用连接).
type JobLock struct {
	conn *pgxpool.Conn
	key  int64
}

// Release 释放集群锁并归还连接; unlock 失败时销毁底层连接 (会话结束锁随之释放), 保证不泄漏.
func (l *JobLock) Release(ctx context.Context) {
	if l == nil || l.conn == nil {
		return
	}
	if _, err := l.conn.Exec(ctx, `SELECT pg_advisory_unlock($1)`, l.key); err != nil {
		_ = l.conn.Conn().Close(ctx)
	}
	l.conn.Release()
	l.conn = nil
}

// jobLockKey 把 job 名映射为稳定 advisory lock key; 前缀防与其它模块的 advisory lock 撞 key.
func jobLockKey(job string) int64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte("drive-worker:" + job))
	return int64(h.Sum64())
}

// TryLockJob 尝试获取某 job 的集群级执行锁 (pg_try_advisory_lock).
// 返回 (nil, false, nil) 表示其它副本正在跑该 job; 成功后调用方必须 Release.
// 覆盖周期调度与手动触发两条路径 (统一在 drive-worker runOnce 收口).
func (r *WorkerJobRepo) TryLockJob(ctx context.Context, job string) (*JobLock, bool, error) {
	conn, err := r.pool.Acquire(ctx)
	if err != nil {
		return nil, false, fmt.Errorf("drive.WorkerJobRepo.TryLockJob.acquire: %w", err)
	}
	key := jobLockKey(job)
	var got bool
	if err := conn.QueryRow(ctx, `SELECT pg_try_advisory_lock($1)`, key).Scan(&got); err != nil {
		conn.Release()
		return nil, false, fmt.Errorf("drive.WorkerJobRepo.TryLockJob: %w", err)
	}
	if !got {
		conn.Release()
		return nil, false, nil
	}
	return &JobLock{conn: conn, key: key}, true, nil
}
