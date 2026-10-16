// admin_platform.go — F06 Phase B platform admin: 用量监控 + drive-worker 状态.
//
// 2 个 svc:
//
//	AdminUsageSvc    /api/admin/v1/platform/drive/usage   全租户用量汇总 (按 tenant 聚合)
//	AdminWorkersSvc  /api/admin/v1/platform/drive/workers drive-worker 5 类 job 状态 (pending 计数 + 配置)
//
// 真实数据来源:
//
//	usage 走 SpaceRepo.UsageSummaryAdmin (drive_spaces × drive_files × drive_quotas)
//	workers 走 TicketRepo.CountExpiredPending + RecycleRepo.CountExpired + FileVersionRepo.CountExcess
//
// 不持久化 last_run/last_error: 当前 drive-worker 进程不写 job stats 表; admin 页面以"实时 pending +
// 配置摘要"为主, last_run 字段留 nil 等后续 instrumentation 上线再填. 不造假.
package drive

import (
	"context"
	"database/sql"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// =====================================================
// AdminUsageSvc
// =====================================================

type AdminUsageSvc struct {
	spaces *drepo.SpaceRepo
}

func NewAdminUsageSvc(s *drepo.SpaceRepo) *AdminUsageSvc {
	return &AdminUsageSvc{spaces: s}
}

// AdminUsageRow JSON shape; 与前端 wrapper DriveUsageRow 对齐.
type AdminUsageRow struct {
	TenantID               int64  `json:"tenant_id"`
	TenantName             string `json:"tenant_name,omitempty"`
	TenantStatus           string `json:"tenant_status,omitempty"`
	SpacesCount            int64  `json:"spaces_count"`
	PersonalSpacesCount    int64  `json:"personal_spaces_count"`
	CollabSpacesCount      int64  `json:"collaboration_spaces_count"`
	FilesCount             int64  `json:"files_count"`
	UsedBytes              int64  `json:"used_bytes"`
	PersonalUsedBytes      int64  `json:"personal_used_bytes"`
	CollaborationUsedBytes int64  `json:"collaboration_used_bytes"`
	QuotaBytes             *int64 `json:"quota_bytes,omitempty"`
}

type AdminUsageListResp struct {
	Items []AdminUsageRow `json:"items"`
	Total int64           `json:"total"`
}

// List 聚合全租户用量汇总.
//   - q: 租户名模糊 (ILIKE, 特殊符转义) 或 tenant_id 精确; 空串不过滤.
//   - sort: usage_desc (默认) | usage_asc | tenant_id; 白名单外 400.
func (s *AdminUsageSvc) List(ctx context.Context, tenantID int64, q, tenantStatus, sort string, limit, offset int) (*AdminUsageListResp, error) {
	if tenantStatus == "" {
		tenantStatus = "active"
	}
	switch tenantStatus {
	case "active", "trial", "suspended", "deactivated", "all":
	default:
		return nil, apperr.ErrInvalidParams.Withf("tenant_status must be active, trial, suspended, deactivated, or all")
	}
	switch sort {
	case "", "usage_desc", "usage_asc", "tenant_id":
	default:
		return nil, apperr.ErrInvalidParams.Withf("sort must be usage_desc, usage_asc, or tenant_id")
	}
	rows, total, err := s.spaces.UsageSummaryAdmin(ctx, tenantID, q, tenantStatus, sort, limit, offset)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]AdminUsageRow, 0, len(rows))
	for i := range rows {
		r := &rows[i]
		out = append(out, AdminUsageRow{
			TenantID:               r.TenantID,
			TenantName:             r.TenantName,
			TenantStatus:           r.TenantStatus,
			SpacesCount:            r.SpacesCount,
			PersonalSpacesCount:    r.PersonalSpacesCount,
			CollabSpacesCount:      r.CollabSpacesCount,
			FilesCount:             r.FilesCount,
			UsedBytes:              r.UsedBytes,
			PersonalUsedBytes:      r.PersonalUsedBytes,
			CollaborationUsedBytes: r.CollaborationUsedBytes,
			QuotaBytes:             r.QuotaBytes,
		})
	}
	return &AdminUsageListResp{Items: out, Total: total}, nil
}

// AdminUsageSummaryResp /platform/drive/usage/summary 平台汇总卡 JSON shape.
// 与列表同过滤口径, 不分页; near_quota 阈值 0.8 与前端占比预警色对齐.
type AdminUsageSummaryResp struct {
	TenantsCount           int64 `json:"tenants_count"`
	SpacesCount            int64 `json:"spaces_count"`
	FilesCount             int64 `json:"files_count"`
	UsedBytes              int64 `json:"used_bytes"`
	PersonalUsedBytes      int64 `json:"personal_used_bytes"`
	CollaborationUsedBytes int64 `json:"collaboration_used_bytes"`
	QuotaSetCount          int64 `json:"quota_set_count"`
	NearQuotaCount         int64 `json:"near_quota_count"`
}

// Summary 平台用量汇总卡数据; 过滤参数语义与 List 一致.
func (s *AdminUsageSvc) Summary(ctx context.Context, tenantID int64, q, tenantStatus string) (*AdminUsageSummaryResp, error) {
	if tenantStatus == "" {
		tenantStatus = "active"
	}
	switch tenantStatus {
	case "active", "trial", "suspended", "deactivated", "all":
	default:
		return nil, apperr.ErrInvalidParams.Withf("tenant_status must be active, trial, suspended, deactivated, or all")
	}
	row, err := s.spaces.UsagePlatformSummary(ctx, tenantID, q, tenantStatus)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return &AdminUsageSummaryResp{
		TenantsCount:           row.TenantsCount,
		SpacesCount:            row.SpacesCount,
		FilesCount:             row.FilesCount,
		UsedBytes:              row.UsedBytes,
		PersonalUsedBytes:      row.PersonalUsedBytes,
		CollaborationUsedBytes: row.CollaborationUsedBytes,
		QuotaSetCount:          row.QuotaSetCount,
		NearQuotaCount:         row.NearQuotaCount,
	}, nil
}

// =====================================================
// AdminPlatformQuotaSvc · F06 v0.3.1 §3.3 — 平台 admin 调整某租户云盘总额度.
// 区别于 AdminQuotaSvc (租户 scope, 只调 per-account): 这里是 platform scope, 只调 tenant 总额.
// =====================================================

type AdminPlatformQuotaSvc struct {
	quotas *drepo.QuotaRepo
}

func NewAdminPlatformQuotaSvc(q *drepo.QuotaRepo) *AdminPlatformQuotaSvc {
	return &AdminPlatformQuotaSvc{quotas: q}
}

// SetTenantQuota 设置某租户总额度.
//   - quotaBytes = -1 → 无限 (跳过 used 校验; -1 永远 >= used)
//   - quotaBytes >= 0 → 校 quotaBytes >= 实时 used_bytes; 不允许设小于已用 (避免后端 atomic
//     UPDATE 全部失败 + 用户体感 "明明有 quota 却传不上去"). 不允许 → 412 drive.quota_below_used.
//   - updatedBy = platform admin caller id.
//
// used_bytes 实时来源: drive_spaces.used_bytes 列累加 (与 confirm 路径 AddUsedBytesTx 一致),
// 而非 drive_quotas.used_bytes (后者可能历史漂移; 这里用最稳的源).
func (s *AdminPlatformQuotaSvc) SetTenantQuota(ctx context.Context, tenantID, quotaBytes, updatedBy int64) error {
	if tenantID <= 0 {
		return apperr.ErrInvalidParams.Withf("tenant_id required")
	}
	if quotaBytes < -1 {
		return apperr.ErrInvalidParams.Withf("quota_bytes must be >= -1 (-1 = unlimited)")
	}
	if quotaBytes >= 0 {
		used, err := s.quotas.SumTenantUsedBytes(ctx, tenantID)
		if err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
		if quotaBytes < used {
			return apperr.New(apperr.PreconditionFailed, "drive.quota_below_used").
				Withf("当前已用 %d 字节, 新额度 %d 字节小于已用; 请先清理或设置 -1 (无限)", used, quotaBytes)
		}
	}
	if err := s.quotas.UpsertTenantQuota(ctx, tenantID, quotaBytes, updatedBy); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	return nil
}

// =====================================================
// AdminWorkersSvc
// =====================================================

type AdminWorkersSvc struct {
	pool       *pgxpool.Pool
	tickets    *drepo.TicketRepo
	recycle    *drepo.RecycleRepo
	versions   *drepo.FileVersionRepo
	workerJobs *drepo.WorkerJobRepo
	// 与 WorkerSvc 同步的默认值; 这里用读 WorkerSvc 字段最稳, 但为避免循环依赖, 复制默认值即可.
	stagingGracePeriod time.Duration
	versionKeepLatest  int
}

func NewAdminWorkersSvc(
	pool *pgxpool.Pool,
	tickets *drepo.TicketRepo,
	recycle *drepo.RecycleRepo,
	versions *drepo.FileVersionRepo,
	workerJobs *drepo.WorkerJobRepo,
) *AdminWorkersSvc {
	return &AdminWorkersSvc{
		pool:               pool,
		tickets:            tickets,
		recycle:            recycle,
		versions:           versions,
		workerJobs:         workerJobs,
		stagingGracePeriod: 1 * time.Hour, // 与 WorkerSvc 默认对齐
		versionKeepLatest:  10,
	}
}

// AdminWorkerJobStatus JSON shape; 与前端 wrapper DriveWorkerJobStatus 对齐.
type AdminWorkerJobStatus struct {
	Job                 string `json:"job"`
	Status              string `json:"status,omitempty"`
	LastRunAt           string `json:"last_run_at,omitempty"`
	LastFinishedAt      string `json:"last_finished_at,omitempty"`
	LastRunDurationMs   *int64 `json:"last_run_duration_ms,omitempty"`
	LastProcessed       *int64 `json:"last_processed,omitempty"`
	LastSuccess         *int64 `json:"last_success,omitempty"`
	LastFailed          *int64 `json:"last_failed,omitempty"`
	LastError           string `json:"last_error,omitempty"`
	ConsecutiveFailures int64  `json:"consecutive_failures,omitempty"`
	PendingCount        *int64 `json:"pending_count,omitempty"`
	Enabled             bool   `json:"enabled"`
	// 2026-07-06 增补 (F06 §4.7): 调度周期 / 下次运行推算 / 停摆判定 / 手动触发排队中.
	IntervalSeconds int64  `json:"interval_seconds,omitempty"`
	NextDueAt       string `json:"next_due_at,omitempty"`
	Stalled         bool   `json:"stalled,omitempty"`
	TriggerPending  bool   `json:"trigger_pending,omitempty"`
}

type AdminWorkersListResp struct {
	Items []AdminWorkerJobStatus `json:"items"`
}

// List 返回 5 类 job 状态.
//   - staging_reaper:  pending = 过期 ticket 数 (now - stagingGrace 之后仍 pending)
//   - recycle_cleaner: pending = expired recycle 行数
//   - version_cleaner: pending = 版本数 > keepLatest 的 file 数
//   - copy_executor:   Phase 2.11/2.12 是 sync inline; 无 async 队列; 显示 enabled=false + pending=nil
//   - thumbnail:       未上线; enabled=false + pending=nil
func (s *AdminWorkersSvc) List(ctx context.Context) (*AdminWorkersListResp, error) {
	now := time.Now()

	stagingPending, err := s.tickets.CountExpiredPending(ctx, now.Add(-s.stagingGracePeriod))
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	recyclePending, err := s.recycle.CountExpired(ctx)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	versionPending, err := s.versions.CountExcess(ctx, s.versionKeepLatest)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	int64Ptr := func(v int64) *int64 { return &v }
	statuses, err := s.listWorkerJobStatus(ctx)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	items := []AdminWorkerJobStatus{
		mergeWorkerStatus(AdminWorkerJobStatus{
			Job:          "staging_reaper",
			Enabled:      true,
			PendingCount: int64Ptr(stagingPending),
		}, statuses),
		mergeWorkerStatus(AdminWorkerJobStatus{
			Job:          "recycle_cleaner",
			Enabled:      true,
			PendingCount: int64Ptr(recyclePending),
		}, statuses),
		mergeWorkerStatus(AdminWorkerJobStatus{
			Job:          "version_cleaner",
			Enabled:      true,
			PendingCount: int64Ptr(versionPending),
		}, statuses),
		{
			Job:     "copy_executor",
			Status:  "disabled",
			Enabled: false,
		},
		{
			Job:     "thumbnail",
			Status:  "disabled",
			Enabled: false,
		},
	}

	pendingTriggers, err := s.workerJobs.PendingTriggerJobs(ctx)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	for i := range items {
		decorateWorkerSchedule(&items[i], pendingTriggers, now)
	}
	return &AdminWorkersListResp{Items: items}, nil
}

// decorateWorkerSchedule 按 WorkerJobIntervals 推算 interval_seconds / next_due_at,
// 判定 stalled (enabled 且 从未运行 或 now-last_run_at > 3×interval), 并标记 trigger_pending.
func decorateWorkerSchedule(it *AdminWorkerJobStatus, pendingTriggers map[string]bool, now time.Time) {
	if !it.Enabled {
		return
	}
	interval, ok := WorkerJobIntervals[it.Job]
	if !ok {
		return
	}
	it.IntervalSeconds = int64(interval / time.Second)
	it.TriggerPending = pendingTriggers[it.Job]
	if it.LastRunAt == "" {
		// 状态行存在但从未跑过 (fresh 部署 / worker 未启动) — 亦视为停摆提示.
		it.Stalled = true
		return
	}
	lastRun, perr := time.Parse(time.RFC3339, it.LastRunAt)
	if perr != nil {
		return
	}
	it.NextDueAt = lastRun.Add(interval).UTC().Format(time.RFC3339)
	if now.Sub(lastRun) > 3*interval {
		it.Stalled = true
	}
}

func mergeWorkerStatus(base AdminWorkerJobStatus, statuses map[string]AdminWorkerJobStatus) AdminWorkerJobStatus {
	if row, ok := statuses[base.Job]; ok {
		row.PendingCount = base.PendingCount
		row.Enabled = base.Enabled
		return row
	}
	base.Status = "success"
	return base
}

func (s *AdminWorkersSvc) listWorkerJobStatus(ctx context.Context) (map[string]AdminWorkerJobStatus, error) {
	rows, err := s.pool.Query(ctx, `
SELECT job, status, enabled, last_run_at, last_finished_at, last_run_duration_ms,
       last_processed, last_success, last_failed, COALESCE(last_error, ''),
       consecutive_failures
  FROM drive_worker_job_status`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]AdminWorkerJobStatus)
	for rows.Next() {
		var (
			item        AdminWorkerJobStatus
			runAt       sql.NullTime
			finishedAt  sql.NullTime
			durationMS  sql.NullInt64
			processed   int64
			success     int64
			failed      int64
			lastError   string
			consecutive int64
		)
		if err := rows.Scan(&item.Job, &item.Status, &item.Enabled, &runAt, &finishedAt, &durationMS,
			&processed, &success, &failed, &lastError, &consecutive); err != nil {
			return nil, err
		}
		if runAt.Valid {
			item.LastRunAt = runAt.Time.UTC().Format(time.RFC3339)
		}
		if finishedAt.Valid {
			item.LastFinishedAt = finishedAt.Time.UTC().Format(time.RFC3339)
		}
		if durationMS.Valid {
			item.LastRunDurationMs = &durationMS.Int64
		}
		item.LastProcessed = &processed
		item.LastSuccess = &success
		item.LastFailed = &failed
		item.LastError = lastError
		item.ConsecutiveFailures = consecutive
		out[item.Job] = item
	}
	return out, rows.Err()
}

// adminWorkerJobKnown 5 类 job 白名单 (失败明细查询用; 可触发白名单更窄, 见 WorkerJobIntervals).
func adminWorkerJobKnown(job string) bool {
	switch job {
	case "staging_reaper", "recycle_cleaner", "version_cleaner", "copy_executor", "thumbnail":
		return true
	}
	return false
}

// AdminWorkerFailure 失败明细行 JSON shape.
type AdminWorkerFailure struct {
	ID         int64  `json:"id"`
	TenantID   *int64 `json:"tenant_id,omitempty"`
	ObjectKind string `json:"object_kind"`
	ObjectRef  string `json:"object_ref"`
	Reason     string `json:"reason"`
	OccurredAt string `json:"occurred_at"`
}

type AdminWorkerFailuresResp struct {
	Items []AdminWorkerFailure `json:"items"`
	Total int64                `json:"total"`
}

// ListFailures 分页列某 job 最近失败对象明细 (drive_worker_job_failures, 14 天滚动保留).
func (s *AdminWorkersSvc) ListFailures(ctx context.Context, job string, limit, offset int) (*AdminWorkerFailuresResp, error) {
	if !adminWorkerJobKnown(job) {
		return nil, apperr.ErrInvalidParams.Withf("unknown worker job %q", job)
	}
	if limit <= 0 || limit > 200 {
		limit = 20
	}
	if offset < 0 {
		offset = 0
	}
	rows, total, err := s.workerJobs.ListFailures(ctx, job, limit, offset)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	items := make([]AdminWorkerFailure, 0, len(rows))
	for i := range rows {
		f := &rows[i]
		items = append(items, AdminWorkerFailure{
			ID:         f.ID,
			TenantID:   f.TenantID,
			ObjectKind: f.ObjectKind,
			ObjectRef:  f.ObjectRef,
			Reason:     f.Reason,
			OccurredAt: f.OccurredAt.UTC().Format(time.RFC3339),
		})
	}
	return &AdminWorkerFailuresResp{Items: items, Total: total}, nil
}

// AdminWorkerTriggerResp 手动触发响应; already_pending=true 表示已有排队请求 (幂等 NOOP).
type AdminWorkerTriggerResp struct {
	Queued         bool `json:"queued"`
	AlreadyPending bool `json:"already_pending,omitempty"`
}

// Trigger 手动触发一轮; 仅 WorkerJobIntervals 白名单内 (3 个 enabled) job 可触发.
// requestedBy = 平台 admin caller account id; drive-worker 每 10s 轮询消费.
func (s *AdminWorkersSvc) Trigger(ctx context.Context, job string, requestedBy int64) (*AdminWorkerTriggerResp, error) {
	if _, ok := WorkerJobIntervals[job]; !ok {
		return nil, apperr.ErrInvalidParams.Withf("worker job %q is not manually triggerable", job)
	}
	queued, err := s.workerJobs.EnqueueTrigger(ctx, job, requestedBy)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return &AdminWorkerTriggerResp{Queued: queued, AlreadyPending: !queued}, nil
}
