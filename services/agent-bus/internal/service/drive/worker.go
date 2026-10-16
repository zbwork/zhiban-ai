// worker.go — F06 Slice B5 drive-worker 服务层.
//
// 3 个 job (无 HTTP; cmd/drive-worker 周期性调用):
//
//	StagingReaper   每 5 分钟: drive_upload_tickets WHERE status='pending' AND expires_at < now-grace
//	                → store.AbortMultipart (若 multipart) + store.Delete(staging_key) + ticket → 'aborted'
//
//	RecycleCleaner  每 1 小时: drive_recycle_bin WHERE expires_at < now
//	                → 对 file 行: store.Delete(storage_key) + drive_files HardDelete + quota release
//	                              + space.used_bytes -= bytes
//	                → 对 folder 行: 仅物理删 (folder 自身 0 字节)
//	                → recycle 行 HardDelete
//	                (与 RecycleSvc.Purge TX 流程一致, 但 caller 是后台无 caller account)
//
//	VersionCleaner  每 6 小时: 找出 drive_file_versions 数 > keepLatest 的 file_id, 把超出部分
//	                按 version_no ASC (最旧的) 删除 → store.Delete + HardDeleteByID.
//
// 全部 idempotent; per-batch 限 limit=N (默认 100), 不一次性扫全表防 long lock.
// Storage 失败仅 slog (不打挂整个 batch); DB 操作放最后, 失败留下行供下次 retry.
package drive

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// WorkerSvc B5: 三个 backend job 的服务编排; cmd/drive-worker 调用方.
type WorkerSvc struct {
	pool     *pgxpool.Pool
	tickets  *drepo.TicketRepo
	recycle  *drepo.RecycleRepo
	files    *drepo.FileRepo
	folders  *drepo.FolderRepo
	versions *drepo.FileVersionRepo
	spaces   *drepo.SpaceRepo
	quotas   *drepo.QuotaRepo
	storage  StorageGetter
	// workerJobs 失败明细 + 手动触发队列; nil 时跳过明细落库 (兼容不关心明细的调用方).
	workerJobs *drepo.WorkerJobRepo

	// staging reaper 的 grace: ticket expires_at 之后再多放多久才能清 (防客户端正在 PUT)
	stagingGrace time.Duration
	// version cleaner 保留几个最新历史版本
	versionKeepLatest int
	// batch limit
	batchLimit int
}

// WorkerJobIntervals 3 个 enabled job 的调度周期. cmd/drive-worker 的 ticker 与
// admin 看板 (interval_seconds / next_due_at / stalled 推算) 共读这一份, 防两处漂移;
// key 集合同时定义「可手动触发的 job」白名单 (F06 §4.7 2026-07-06 增补).
var WorkerJobIntervals = map[string]time.Duration{
	"staging_reaper":  5 * time.Minute,
	"recycle_cleaner": 1 * time.Hour,
	"version_cleaner": 6 * time.Hour,
}

// WorkerRunStats 是一次 drive-worker job 的业务处理结果.
type WorkerRunStats struct {
	Processed int64
	Failed    int64
	// Failures 本轮单对象失败明细, cap 到 batch 上限; 随 MarkWorkerJobFinished best-effort 落库.
	// Failed 计数与明细条数可能不等 (version_cleaner 有按批计 Failed、按对象记明细的路径).
	Failures []dom.WorkerJobFailure
}

// addFailure 追加一条失败明细 (超 cap 丢弃, 只保计数); Failed 计数由调用处维护.
func (st *WorkerRunStats) addFailure(capN int, job string, tenantID *int64, kind, ref, reason string) {
	if len(st.Failures) >= capN {
		return
	}
	st.Failures = append(st.Failures, dom.WorkerJobFailure{
		Job:        job,
		TenantID:   tenantID,
		ObjectKind: kind,
		ObjectRef:  ref,
		Reason:     reason,
		OccurredAt: time.Now(),
	})
}

// i64ptr 取值拷贝的指针 (防循环变量别名).
func i64ptr(v int64) *int64 { return &v }

// NewWorkerSvc 构造. 默认 stagingGrace=1h, versionKeepLatest=10, batchLimit=100.
func NewWorkerSvc(
	pool *pgxpool.Pool,
	tickets *drepo.TicketRepo,
	recycle *drepo.RecycleRepo,
	files *drepo.FileRepo,
	folders *drepo.FolderRepo,
	versions *drepo.FileVersionRepo,
	spaces *drepo.SpaceRepo,
	quotas *drepo.QuotaRepo,
	storage StorageGetter,
	workerJobs *drepo.WorkerJobRepo,
) *WorkerSvc {
	return &WorkerSvc{
		pool:              pool,
		tickets:           tickets,
		recycle:           recycle,
		files:             files,
		folders:           folders,
		versions:          versions,
		spaces:            spaces,
		quotas:            quotas,
		storage:           storage,
		workerJobs:        workerJobs,
		stagingGrace:      1 * time.Hour,
		versionKeepLatest: 10,
		batchLimit:        100,
	}
}

// WithBatchLimit 覆盖 batch 大小 (测试用 / 部署 tuning).
func (s *WorkerSvc) WithBatchLimit(n int) *WorkerSvc {
	if n > 0 {
		s.batchLimit = n
	}
	return s
}

// WithVersionKeepLatest 覆盖版本保留数 (≥ 0).
func (s *WorkerSvc) WithVersionKeepLatest(n int) *WorkerSvc {
	if n >= 0 {
		s.versionKeepLatest = n
	}
	return s
}

// WithStagingGrace 覆盖 staging grace 时长 (≥ 0; 0 = 不等任何 grace, 完全按 expires_at).
func (s *WorkerSvc) WithStagingGrace(d time.Duration) *WorkerSvc {
	if d >= 0 {
		s.stagingGrace = d
	}
	return s
}

// RunStagingReaper 处理一批过期 staging upload tickets.
// 返 (processed, skipped, error); error 通常是 DB 列表失败; per-item 失败仅 slog.
func (s *WorkerSvc) RunStagingReaper(ctx context.Context) (processed int, err error) {
	stats, err := s.RunStagingReaperWithStats(ctx)
	return int(stats.Processed), err
}

// RunStagingReaperWithStats 处理一批过期 staging upload tickets, 并返回成功/失败计数.
func (s *WorkerSvc) RunStagingReaperWithStats(ctx context.Context) (WorkerRunStats, error) {
	before := time.Now().Add(-s.stagingGrace)
	rows, err := s.tickets.ListExpiredPending(ctx, before, s.batchLimit)
	if err != nil {
		return WorkerRunStats{}, fmt.Errorf("drive.WorkerSvc.RunStagingReaper.list: %w", err)
	}
	var stats WorkerRunStats
	for i := range rows {
		t := &rows[i]
		store, sErr := s.storage.Resolve(ctx, t.TenantID)
		if sErr != nil {
			slog.ErrorContext(ctx, "drive.worker.staging_reaper.storage_resolve_failed",
				"tenant_id", t.TenantID, "file_uuid", t.FileUUID, "err", sErr.Error())
			stats.Failed++
			stats.addFailure(s.batchLimit, "staging_reaper", i64ptr(t.TenantID),
				"upload_ticket", t.FileUUID, "解析租户存储配置失败: "+sErr.Error())
			continue
		}
		// 多 part: 先 AbortMultipart (若 upload_id 非空); single mode 跳过.
		if t.UploadID != nil && *t.UploadID != "" {
			if err := store.AbortMultipart(ctx, t.StagingKey, *t.UploadID); err != nil {
				slog.WarnContext(ctx, "drive.worker.staging_reaper.abort_multipart_failed",
					"tenant_id", t.TenantID, "file_uuid", t.FileUUID, "err", err.Error())
				// 继续往下走 (S3 已 expire multipart 也是常见; 不影响标 failed)
			}
		}
		// 删 staging key (best-effort)
		if err := store.Delete(ctx, t.StagingKey); err != nil && !errors.Is(err, object.ErrNotFound) {
			slog.WarnContext(ctx, "drive.worker.staging_reaper.delete_failed",
				"tenant_id", t.TenantID, "file_uuid", t.FileUUID, "key", t.StagingKey, "err", err.Error())
		}
		// 标 ticket failed (status enum: pending / done / failed / partial / aborted) — 'aborted' 视为 reaper 主动清理.
		// 当前 schema status 由 service 用字符串注入 (无 enum), 我们用 'aborted' 标识 reaper 关单.
		if err := s.tickets.UpdateStatus(ctx, t.FileUUID, "aborted"); err != nil {
			slog.WarnContext(ctx, "drive.worker.staging_reaper.update_status_failed",
				"tenant_id", t.TenantID, "file_uuid", t.FileUUID, "err", err.Error())
			stats.Failed++
			stats.addFailure(s.batchLimit, "staging_reaper", i64ptr(t.TenantID),
				"upload_ticket", t.FileUUID, "更新 ticket 状态失败: "+err.Error())
			continue
		}
		stats.Processed++
	}
	return stats, nil
}

// RunRecycleCleaner 处理一批过期 recycle entries (file → S3 delete + quota release; folder → 仅删行).
// 返 processed = 实际成功 HardDelete 的 recycle 行数.
func (s *WorkerSvc) RunRecycleCleaner(ctx context.Context) (processed int, err error) {
	stats, err := s.RunRecycleCleanerWithStats(ctx)
	return int(stats.Processed), err
}

// RunRecycleCleanerWithStats 处理一批过期 recycle entries, 并返回成功/失败计数.
func (s *WorkerSvc) RunRecycleCleanerWithStats(ctx context.Context) (WorkerRunStats, error) {
	before := time.Now()
	rows, err := s.recycle.ListExpired(ctx, before, s.batchLimit)
	if err != nil {
		return WorkerRunStats{}, fmt.Errorf("drive.WorkerSvc.RunRecycleCleaner.list: %w", err)
	}
	var stats WorkerRunStats
	for i := range rows {
		entry := &rows[i]
		if perItemErr := s.PurgeOne(ctx, entry); perItemErr != nil {
			slog.ErrorContext(ctx, "drive.worker.recycle_cleaner.item_failed",
				"recycle_id", entry.ID, "target_kind", entry.TargetKind, "err", perItemErr.Error())
			stats.Failed++
			stats.addFailure(s.batchLimit, "recycle_cleaner", i64ptr(entry.TenantID),
				"recycle_entry", entry.UUID, "清理回收站条目失败: "+perItemErr.Error())
			continue
		}
		stats.Processed++
	}
	return stats, nil
}

// PurgeOne 处理 1 条 recycle entry: TX 内物理删 file/folder + 释放 quota + 删 recycle 行;
// TX 外做 best-effort S3 delete (失败仅 slog).
// 公开方法 — admin 端 RecycleAdmin.Purge 直接复用 (admin 已 ACL 把关, 行级再次校验由 LockByUUIDTx 保证).
func (s *WorkerSvc) PurgeOne(ctx context.Context, entry *dom.RecycleEntry) error {
	var (
		storageKey   string
		releaseBytes int64
		fileCreator  *int64 // file purge 时按 file.CreatedBy 释放 account quota
	)
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	// 锁 recycle 行 (FOR UPDATE) — 防并发 restore / 重复 purge
	if _, err := s.recycle.LockByUUIDTx(ctx, tx, entry.UUID); err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			// 被并发 tombstone / 已删 — skip
			return nil
		}
		return fmt.Errorf("lock recycle: %w", err)
	}

	switch entry.TargetKind {
	case dom.RecycleTargetFile:
		file, err := s.files.LockByIDTx(ctx, tx, entry.TargetID)
		if err != nil {
			if errors.Is(err, drepo.ErrNotFound) {
				// 文件已被 hard-delete (上次 purge 跑了一半); 只删 recycle 行
				return s.recycle.HardDeleteTx(ctx, tx, entry.ID)
			}
			return fmt.Errorf("lock file: %w", err)
		}
		storageKey = file.StorageKey
		releaseBytes = file.SizeBytes
		fileCreator = file.CreatedBy

		if err := s.files.HardDeleteByIDTx(ctx, tx, entry.TargetID); err != nil {
			return fmt.Errorf("hard-delete file: %w", err)
		}
	case dom.RecycleTargetFolder:
		// 文件 0 字节; HardDelete folder 行
		if err := s.folders.HardDeleteByIDTx(ctx, tx, entry.TargetID); err != nil {
			if !errors.Is(err, drepo.ErrNotFound) {
				return fmt.Errorf("hard-delete folder: %w", err)
			}
			// 不存在视为已删, 继续清 recycle 行
		}
	default:
		return fmt.Errorf("unknown target_kind %q", entry.TargetKind)
	}

	// quota / used_bytes 释放 (file 才有 bytes; folder=0).
	if releaseBytes > 0 {
		// tenant quota
		if tq, qErr := s.quotas.GetForTenant(ctx, entry.TenantID); qErr == nil && tq != nil {
			if err := s.quotas.AddUsedBytesSignedTx(ctx, tx, tq.ID, -releaseBytes); err != nil {
				return fmt.Errorf("release tenant quota: %w", err)
			}
		}
		// account quota — 按 file.CreatedBy (不是 entry.DeletedBy; deleter 可能不是 owner)
		if fileCreator != nil {
			if aq, qErr := s.quotas.GetForAccount(ctx, entry.TenantID, *fileCreator); qErr == nil && aq != nil {
				if err := s.quotas.AddUsedBytesSignedTx(ctx, tx, aq.ID, -releaseBytes); err != nil {
					return fmt.Errorf("release account quota: %w", err)
				}
			}
		}
		// space used_bytes
		if err := s.spaces.AddUsedBytesSignedTx(ctx, tx, entry.SpaceID, -releaseBytes); err != nil {
			return fmt.Errorf("release space used: %w", err)
		}
	}

	// 删 recycle 行
	if err := s.recycle.HardDeleteTx(ctx, tx, entry.ID); err != nil {
		return fmt.Errorf("hard-delete recycle: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	committed = true

	// TX 外 best-effort S3 delete (recycle 行已删, 失败留 orphan object 由 storage life-cycle policy 兜底)
	if storageKey != "" {
		store, sErr := s.storage.Resolve(ctx, entry.TenantID)
		if sErr != nil {
			slog.WarnContext(ctx, "drive.worker.recycle_cleaner.storage_resolve_failed",
				"tenant_id", entry.TenantID, "key", storageKey, "err", sErr.Error())
			return nil
		}
		if err := store.Delete(ctx, storageKey); err != nil && !errors.Is(err, object.ErrNotFound) {
			slog.WarnContext(ctx, "drive.worker.recycle_cleaner.s3_delete_failed",
				"tenant_id", entry.TenantID, "key", storageKey, "err", err.Error())
		}
	}
	return nil
}

// RunVersionCleaner 把每个 file 的版本数缩到 versionKeepLatest 条 (按 version_no DESC 保留最新).
// 返 processed = 实际 hard-delete 的版本行数 (跨 file 累加).
func (s *WorkerSvc) RunVersionCleaner(ctx context.Context) (processed int, err error) {
	stats, err := s.RunVersionCleanerWithStats(ctx)
	return int(stats.Processed), err
}

// RunVersionCleanerWithStats 把每个 file 的版本数缩到 versionKeepLatest 条, 并返回成功/失败计数.
func (s *WorkerSvc) RunVersionCleanerWithStats(ctx context.Context) (WorkerRunStats, error) {
	fileIDs, err := s.versions.ListFileIDsWithExcess(ctx, s.versionKeepLatest, s.batchLimit)
	if err != nil {
		return WorkerRunStats{}, fmt.Errorf("drive.WorkerSvc.RunVersionCleaner.list: %w", err)
	}
	var stats WorkerRunStats
	for _, fileID := range fileIDs {
		// 拉全部 (DESC; 第 0 是最新)
		rows, lErr := s.versions.ListByFileID(ctx, fileID)
		if lErr != nil {
			slog.ErrorContext(ctx, "drive.worker.version_cleaner.list_failed",
				"file_id", fileID, "err", lErr.Error())
			stats.Failed++
			stats.addFailure(s.batchLimit, "version_cleaner", nil,
				"file", strconv.FormatInt(fileID, 10), "列文件版本失败: "+lErr.Error())
			continue
		}
		if len(rows) <= s.versionKeepLatest {
			continue
		}
		// 取超出部分: rows[keepLatest:] (这些是旧版本)
		excess := rows[s.versionKeepLatest:]

		// resolve store: 先取一行 file 拿 tenantID (version 没存 tenantID)
		file, fErr := s.files.GetByID(ctx, fileID)
		if fErr != nil {
			slog.ErrorContext(ctx, "drive.worker.version_cleaner.file_resolve_failed",
				"file_id", fileID, "err", fErr.Error())
			stats.Failed += int64(len(excess))
			stats.addFailure(s.batchLimit, "version_cleaner", nil,
				"file", strconv.FormatInt(fileID, 10),
				fmt.Sprintf("解析文件失败 (影响 %d 个待清版本): %s", len(excess), fErr.Error()))
			continue
		}
		space, spErr := s.spaces.GetByID(ctx, file.SpaceID)
		if spErr != nil || space == nil {
			slog.ErrorContext(ctx, "drive.worker.version_cleaner.space_resolve_failed",
				"file_id", fileID, "err", fmt.Sprintf("%v", spErr))
			stats.Failed += int64(len(excess))
			stats.addFailure(s.batchLimit, "version_cleaner", nil,
				"file", strconv.FormatInt(fileID, 10),
				fmt.Sprintf("解析所属空间失败 (影响 %d 个待清版本): %v", len(excess), spErr))
			continue
		}
		store, sErr := s.storage.Resolve(ctx, space.TenantID)
		if sErr != nil {
			slog.ErrorContext(ctx, "drive.worker.version_cleaner.storage_resolve_failed",
				"tenant_id", space.TenantID, "err", sErr.Error())
			stats.Failed += int64(len(excess))
			stats.addFailure(s.batchLimit, "version_cleaner", i64ptr(space.TenantID),
				"file", strconv.FormatInt(fileID, 10),
				fmt.Sprintf("解析租户存储配置失败 (影响 %d 个待清版本): %s", len(excess), sErr.Error()))
			continue
		}
		for i := range excess {
			v := &excess[i]
			if err := store.Delete(ctx, v.StorageKey); err != nil && !errors.Is(err, object.ErrNotFound) {
				slog.WarnContext(ctx, "drive.worker.version_cleaner.s3_delete_failed",
					"version_id", v.ID, "key", v.StorageKey, "err", err.Error())
				// 继续 HardDelete — orphan object 由 storage life-cycle 兜底
			}
			if err := s.versions.HardDeleteByID(ctx, v.ID); err != nil {
				slog.ErrorContext(ctx, "drive.worker.version_cleaner.hard_delete_failed",
					"version_id", v.ID, "err", err.Error())
				stats.Failed++
				stats.addFailure(s.batchLimit, "version_cleaner", i64ptr(space.TenantID),
					"file_version", strconv.FormatInt(v.ID, 10), "删除历史版本行失败: "+err.Error())
				continue
			}
			stats.Processed++
		}
	}
	return stats, nil
}

// MarkWorkerJobStarted records that a scheduled drive worker job has begun.
// The method is best-effort for callers; they should log but not fail the job if it errors.
func (s *WorkerSvc) MarkWorkerJobStarted(ctx context.Context, job string, startedAt time.Time) error {
	_, err := s.pool.Exec(ctx, `
INSERT INTO drive_worker_job_status (job, status, enabled, last_run_at, updated_at)
VALUES ($1, 'running', true, $2, now())
ON CONFLICT (job) DO UPDATE SET
  status='running',
  enabled=true,
  last_run_at=EXCLUDED.last_run_at,
  updated_at=now()`, job, startedAt)
	return err
}

// MarkWorkerJobFinished records the latest run result for a scheduled drive worker job.
func (s *WorkerSvc) MarkWorkerJobFinished(ctx context.Context, job string, startedAt, finishedAt time.Time, stats WorkerRunStats, runErr error) error {
	status := "success"
	lastErr := ""
	if runErr != nil {
		status = "failed"
		lastErr = runErr.Error()
		if stats.Failed == 0 {
			stats.Failed = 1
		}
	} else if stats.Failed > 0 {
		status = "failed"
		lastErr = fmt.Sprintf("部分对象处理失败: %d", stats.Failed)
	}
	durationMS := finishedAt.Sub(startedAt).Milliseconds()
	if durationMS < 0 {
		durationMS = 0
	}
	_, err := s.pool.Exec(ctx, `
INSERT INTO drive_worker_job_status (
  job, status, enabled, last_run_at, last_finished_at, last_run_duration_ms,
  last_processed, last_success, last_failed, last_error, consecutive_failures,
  updated_at
) VALUES (
  $1, $2::varchar, true, $3, $4, $5,
  $6, $7, $8, NULLIF($9, ''),
  CASE WHEN $2::varchar='failed' THEN 1 ELSE 0 END,
  now()
)
ON CONFLICT (job) DO UPDATE SET
  status=EXCLUDED.status,
  enabled=true,
  last_run_at=EXCLUDED.last_run_at,
  last_finished_at=EXCLUDED.last_finished_at,
  last_run_duration_ms=EXCLUDED.last_run_duration_ms,
  last_processed=EXCLUDED.last_processed,
  last_success=EXCLUDED.last_success,
  last_failed=EXCLUDED.last_failed,
  last_error=EXCLUDED.last_error,
  consecutive_failures=CASE
    WHEN EXCLUDED.status='failed' THEN drive_worker_job_status.consecutive_failures + 1
    ELSE 0
  END,
  updated_at=now()`, job, status, startedAt, finishedAt, durationMS, stats.Processed, stats.Processed, stats.Failed, lastErr)
	if err != nil {
		return err
	}
	// 失败明细 best-effort 落库; 失败仅记日志, 不影响 job 状态记录.
	if s.workerJobs != nil && len(stats.Failures) > 0 {
		if ferr := s.workerJobs.InsertFailures(ctx, job, stats.Failures); ferr != nil {
			slog.WarnContext(ctx, "drive.worker.failures_persist_failed", "job", job, "err", ferr.Error())
		}
	}
	return nil
}
