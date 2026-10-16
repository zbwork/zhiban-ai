// platform_ops.go — F08 §5.1/§5.3 platform 跨租户 cron 运营监控 (只读) 仓储方法。
//
// 与 tenant 视角的区别: 显式跨租户, 不从 ctx / 参数取单一 tenant_id; 平台 permission
// guard 由 transport 层 platformPerm("platform.cron.read") 保证。全部只读, 不改任何 row。
package cron

import (
	"context"
	"strconv"
	"strings"

	domcron "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/cron"
)

// tenantNames 批查 tenant id → name (跨租户显示名回填共用)。查不到的 id 不入 map。
func (r *Repo) tenantNames(ctx context.Context, ids []int64) (map[int64]string, error) {
	out := map[int64]string{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := r.pool.Query(ctx, `SELECT id, COALESCE(name,'') FROM tenants WHERE id = ANY($1)`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var name string
		if err := rows.Scan(&id, &name); err != nil {
			return nil, err
		}
		out[id] = name
	}
	return out, rows.Err()
}

// FillJobTenantNames · platform 列表显示名回填: 批查 tenant name 填入 Job.TenantName。
// best-effort: 查不到的行留空, 由调用方回退展示 tenant_id。
func (r *Repo) FillJobTenantNames(ctx context.Context, jobs []domcron.Job) error {
	if len(jobs) == 0 {
		return nil
	}
	seen := map[int64]bool{}
	ids := make([]int64, 0, len(jobs))
	for i := range jobs {
		if id := jobs[i].TenantID; id > 0 && !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	names, err := r.tenantNames(ctx, ids)
	if err != nil {
		return err
	}
	for i := range jobs {
		if n, ok := names[jobs[i].TenantID]; ok {
			jobs[i].TenantName = n
		}
	}
	return nil
}

// PlatformListJobs · 跨租户 cron 任务列表 (后端分页, 返回 items + total)。
//
// 租户关键词用子查询匹配 tenant.name / tenant_id, 避免与 agent_cron_jobs 同名列 (id/name/status)
// 做 JOIN 时的歧义; 主查询仍只扫 agent_cron_jobs, 复用 jobCols / scanJob。
func (r *Repo) PlatformListJobs(ctx context.Context, f domcron.PlatformJobsFilter) ([]domcron.Job, int64, error) {
	where := "WHERE deleted_at IS NULL"
	args := []any{}
	idx := 1
	if kw := strings.TrimSpace(f.TenantKeyword); kw != "" {
		where += " AND (tenant_id::text = $" + strconv.Itoa(idx) +
			" OR tenant_id IN (SELECT id FROM tenants WHERE name ILIKE '%'||$" + strconv.Itoa(idx) + "||'%'))"
		args = append(args, kw)
		idx++
	}
	if kw := strings.TrimSpace(f.TaskKeyword); kw != "" {
		where += " AND name ILIKE '%'||$" + strconv.Itoa(idx) + "||'%'"
		args = append(args, kw)
		idx++
	}
	if st := strings.TrimSpace(f.Status); st != "" {
		where += " AND status = $" + strconv.Itoa(idx)
		args = append(args, st)
		idx++
	}
	switch strings.TrimSpace(f.LastResult) {
	case "none":
		where += " AND last_run_at IS NULL"
	case "succeeded", "failed", "running":
		where += " AND last_run_status = $" + strconv.Itoa(idx)
		args = append(args, f.LastResult)
		idx++
	}
	if f.OnlyConsecutiveFailure {
		where += " AND consecutive_failures > 0"
	}

	var total int64
	if err := r.pool.QueryRow(ctx, "SELECT COUNT(*) FROM agent_cron_jobs "+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	if total == 0 {
		return []domcron.Job{}, 0, nil
	}

	limit := f.Limit
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	offset := f.Offset
	if offset < 0 {
		offset = 0
	}
	// 运营排序: 连续失败任务优先置顶, 再按最近运行时间倒序, 最后 id 兜底稳定。
	q := "SELECT " + jobCols + " FROM agent_cron_jobs " + where +
		" ORDER BY (consecutive_failures > 0) DESC, COALESCE(last_run_at, to_timestamp(0)) DESC, id DESC" +
		" LIMIT $" + strconv.Itoa(idx) + " OFFSET $" + strconv.Itoa(idx+1)
	args = append(args, limit, offset)
	rows, err := r.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := make([]domcron.Job, 0, limit)
	for rows.Next() {
		j, err := scanJob(rows)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, *j)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	return out, total, nil
}

// PlatformOverviewCounts · 顶部概览原始计数。24h 口径用于成功/失败次数与最近失败时间;
// 成功率由 service 计算。全表聚合, 依赖 agent_cron_jobs / agent_cron_runs 现有索引。
func (r *Repo) PlatformOverviewCounts(ctx context.Context) (domcron.PlatformOverviewCounts, error) {
	var c domcron.PlatformOverviewCounts
	if err := r.pool.QueryRow(ctx, `
SELECT
  COUNT(*),
  COUNT(*) FILTER (WHERE enabled AND status = 'active'),
  COUNT(*) FILTER (WHERE consecutive_failures > 0),
  MAX(last_run_at)
FROM agent_cron_jobs
WHERE deleted_at IS NULL`).Scan(&c.TotalJobs, &c.ActiveJobs, &c.ConsecutiveFailureJobs, &c.LastRunAt); err != nil {
		return c, err
	}
	if err := r.pool.QueryRow(ctx, `
SELECT
  COUNT(*) FILTER (WHERE status = 'succeeded'),
  COUNT(*) FILTER (WHERE status = 'failed'),
  MAX(started_at) FILTER (WHERE status = 'failed')
FROM agent_cron_runs
WHERE started_at >= now() - interval '24 hours'`).Scan(&c.Runs24hSucceeded, &c.Runs24hFailed, &c.LastFailureAt); err != nil {
		return c, err
	}
	return c, nil
}

// PlatformFailureStats · 轻量失败排行 (§5.3)。失败原因 / 失败租户 走近 24h agent_cron_runs;
// 连续失败走 agent_cron_jobs.consecutive_failures 计数 (非时间窗)。tenant 名批查回填。
func (r *Repo) PlatformFailureStats(ctx context.Context, topN int) ([]domcron.FailureReasonStat, []domcron.FailureTenantStat, []domcron.ConsecutiveFailureStat, error) {
	if topN <= 0 || topN > 20 {
		topN = 5
	}

	reasons := []domcron.FailureReasonStat{}
	rrows, err := r.pool.Query(ctx, `
SELECT COALESCE(NULLIF(error_message, ''), '(无错误信息)') AS reason, COUNT(*)
FROM agent_cron_runs
WHERE status = 'failed' AND started_at >= now() - interval '24 hours'
GROUP BY reason
ORDER BY COUNT(*) DESC, reason
LIMIT $1`, topN)
	if err != nil {
		return nil, nil, nil, err
	}
	for rrows.Next() {
		var s domcron.FailureReasonStat
		if err := rrows.Scan(&s.Reason, &s.Count); err != nil {
			rrows.Close()
			return nil, nil, nil, err
		}
		reasons = append(reasons, s)
	}
	rrows.Close()
	if err := rrows.Err(); err != nil {
		return nil, nil, nil, err
	}

	tenants := []domcron.FailureTenantStat{}
	trows, err := r.pool.Query(ctx, `
SELECT tenant_id, COUNT(*)
FROM agent_cron_runs
WHERE status = 'failed' AND started_at >= now() - interval '24 hours'
GROUP BY tenant_id
ORDER BY COUNT(*) DESC, tenant_id
LIMIT $1`, topN)
	if err != nil {
		return nil, nil, nil, err
	}
	for trows.Next() {
		var s domcron.FailureTenantStat
		if err := trows.Scan(&s.TenantID, &s.Count); err != nil {
			trows.Close()
			return nil, nil, nil, err
		}
		tenants = append(tenants, s)
	}
	trows.Close()
	if err := trows.Err(); err != nil {
		return nil, nil, nil, err
	}

	consec := []domcron.ConsecutiveFailureStat{}
	crows, err := r.pool.Query(ctx, `
SELECT uuid::text, name, tenant_id, consecutive_failures
FROM agent_cron_jobs
WHERE deleted_at IS NULL AND consecutive_failures > 0
ORDER BY consecutive_failures DESC, id DESC
LIMIT $1`, topN)
	if err != nil {
		return nil, nil, nil, err
	}
	for crows.Next() {
		var s domcron.ConsecutiveFailureStat
		if err := crows.Scan(&s.JobUUID, &s.Name, &s.TenantID, &s.ConsecutiveFailures); err != nil {
			crows.Close()
			return nil, nil, nil, err
		}
		consec = append(consec, s)
	}
	crows.Close()
	if err := crows.Err(); err != nil {
		return nil, nil, nil, err
	}

	// 批查 tenant 名回填 (失败租户 + 连续失败两个列表)。
	seen := map[int64]bool{}
	ids := make([]int64, 0, len(tenants)+len(consec))
	for _, t := range tenants {
		if t.TenantID > 0 && !seen[t.TenantID] {
			seen[t.TenantID] = true
			ids = append(ids, t.TenantID)
		}
	}
	for _, c := range consec {
		if c.TenantID > 0 && !seen[c.TenantID] {
			seen[c.TenantID] = true
			ids = append(ids, c.TenantID)
		}
	}
	names, err := r.tenantNames(ctx, ids)
	if err != nil {
		return nil, nil, nil, err
	}
	for i := range tenants {
		tenants[i].TenantName = names[tenants[i].TenantID]
	}
	for i := range consec {
		consec[i].TenantName = names[consec[i].TenantID]
	}
	return reasons, tenants, consec, nil
}
