// platform_ops.go — F08 §5.1/§5.3 platform 跨租户 cron 运营监控 (只读) service 层。
//
// 只读监控视角: 概览统计 + 跨租户任务列表 (后端分页) + 任务详情 (含最近运行记录)。
// V1 不含任何跨租户写操作 (强停/恢复/立即执行等); 那些仍走 tenant scope 的既有接口。
// 详情/运行记录**不**暴露 rendered_prompt_snapshot 与 payload (敏感 prompt 内容)。
package cron

import (
	"context"
	"math"
	"time"

	domcron "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/cron"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// PlatformCronJobDTO · 跨租户列表/详情单行。内嵌 JobDTO (复用既有映射), 额外带租户标识。
type PlatformCronJobDTO struct {
	TenantID   int64  `json:"tenant_id"`
	TenantName string `json:"tenant_name,omitempty"`
	JobDTO
}

// PlatformCronRunDTO · 平台详情里的运行记录。
//
// 平台运营视角只看健康度/状态/时间/失败原因；**不**暴露 Summary —— 现有执行路径里
// agent_cron_runs.summary 来源是 prompt 截断 (service.go: truncate(prompt, 500))，属用户任务内容，
// 平台不应看到。也不含 rendered_prompt / payload 快照。owner 仍可在客户端任务页查看自己的内容。
type PlatformCronRunDTO struct {
	UUID         string     `json:"uuid"`
	Status       string     `json:"status"`
	TriggerKind  string     `json:"trigger_kind,omitempty"`
	StartedAt    time.Time  `json:"started_at"`
	FinishedAt   *time.Time `json:"finished_at,omitempty"`
	DurationMs   int64      `json:"duration_ms,omitempty"`
	ErrorMessage string     `json:"error_message,omitempty"`
	RetryCount   int        `json:"retry_count,omitempty"`
}

// PlatformCronListReq / PlatformCronListDTO · 后端分页列表。
type PlatformCronListReq struct {
	TenantKeyword          string
	TaskKeyword            string
	Status                 string
	LastResult             string
	OnlyConsecutiveFailure bool
	Limit                  int
	Offset                 int
}

type PlatformCronListDTO struct {
	Items []PlatformCronJobDTO `json:"items"`
	Total int64                `json:"total"`
}

// PlatformCronJobDetailDTO · 详情 = 任务信息 + 最近 N 条运行记录。
type PlatformCronJobDetailDTO struct {
	PlatformCronJobDTO
	Runs []PlatformCronRunDTO `json:"runs"`
}

// ---- overview ----

type PlatformFailureReasonDTO struct {
	Reason string `json:"reason"`
	Count  int64  `json:"count"`
}
type PlatformFailureTenantDTO struct {
	TenantID   int64  `json:"tenant_id"`
	TenantName string `json:"tenant_name,omitempty"`
	Count      int64  `json:"count"`
}
type PlatformConsecutiveFailureDTO struct {
	JobUUID             string `json:"job_uuid"`
	Name                string `json:"name"`
	TenantID            int64  `json:"tenant_id"`
	TenantName          string `json:"tenant_name,omitempty"`
	ConsecutiveFailures int    `json:"consecutive_failures"`
}

// PlatformCronOverviewDTO · 顶部概览 + 轻量失败排行。成功率/失败排行均为近 24h 口径;
// 连续失败为 job 累计计数 (非时间窗)。SuccessRate 为 nil 表示 24h 无运行 (前端显示 "-")。
type PlatformCronOverviewDTO struct {
	TotalJobs              int64      `json:"total_jobs"`
	ActiveJobs             int64      `json:"active_jobs"`
	Runs24hSucceeded       int64      `json:"runs_24h_succeeded"`
	Runs24hFailed          int64      `json:"runs_24h_failed"`
	SuccessRate            *float64   `json:"success_rate"` // 百分比 0~100, 1 位小数; null = 24h 无运行
	ConsecutiveFailureJobs int64      `json:"consecutive_failure_jobs"`
	LastRunAt              *time.Time `json:"last_run_at,omitempty"`
	LastFailureAt          *time.Time `json:"last_failure_at,omitempty"`

	TopFailureReasons      []PlatformFailureReasonDTO      `json:"top_failure_reasons"`
	TopFailureTenants      []PlatformFailureTenantDTO      `json:"top_failure_tenants"`
	TopConsecutiveFailures []PlatformConsecutiveFailureDTO `json:"top_consecutive_failures"`
}

// toPlatformJobDTO · Job → PlatformCronJobDTO。复用 toJobDTO, 但抹掉平台不该看的用户任务内容:
//   - Payload: 触发载荷 (含 prompt)。
//   - LastRunSummary: 现有执行路径里由 prompt 截断而来 (service.go: truncate(prompt, 500))，属用户内容。
//
// 调用前应已 FillJobDisplayMeta + FillJobTenantNames。
func (s *impl) toPlatformJobDTO(j *domcron.Job) PlatformCronJobDTO {
	dto := s.toJobDTO(j, j.AgentUUID)
	dto.Payload = nil
	dto.LastRunSummary = ""
	dto.OwnerDisplayName = j.OwnerDisplayName
	dto.AgentName = j.AgentName
	return PlatformCronJobDTO{TenantID: j.TenantID, TenantName: j.TenantName, JobDTO: dto}
}

// PlatformCronOverview · 全平台 cron 运营概览 + 失败排行 (只读)。
func (s *impl) PlatformCronOverview(ctx context.Context) (*PlatformCronOverviewDTO, error) {
	c, err := s.repo.PlatformOverviewCounts(ctx)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	reasons, tenants, consec, err := s.repo.PlatformFailureStats(ctx, 5)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := &PlatformCronOverviewDTO{
		TotalJobs:              c.TotalJobs,
		ActiveJobs:             c.ActiveJobs,
		Runs24hSucceeded:       c.Runs24hSucceeded,
		Runs24hFailed:          c.Runs24hFailed,
		ConsecutiveFailureJobs: c.ConsecutiveFailureJobs,
		LastRunAt:              c.LastRunAt,
		LastFailureAt:          c.LastFailureAt,
		TopFailureReasons:      make([]PlatformFailureReasonDTO, 0, len(reasons)),
		TopFailureTenants:      make([]PlatformFailureTenantDTO, 0, len(tenants)),
		TopConsecutiveFailures: make([]PlatformConsecutiveFailureDTO, 0, len(consec)),
	}
	if tot := c.Runs24hSucceeded + c.Runs24hFailed; tot > 0 {
		rate := math.Round(float64(c.Runs24hSucceeded)*1000/float64(tot)) / 10 // 1 位小数百分比
		out.SuccessRate = &rate
	}
	for _, r := range reasons {
		out.TopFailureReasons = append(out.TopFailureReasons, PlatformFailureReasonDTO{Reason: r.Reason, Count: r.Count})
	}
	for _, t := range tenants {
		out.TopFailureTenants = append(out.TopFailureTenants, PlatformFailureTenantDTO{TenantID: t.TenantID, TenantName: t.TenantName, Count: t.Count})
	}
	for _, cc := range consec {
		out.TopConsecutiveFailures = append(out.TopConsecutiveFailures, PlatformConsecutiveFailureDTO{
			JobUUID: cc.JobUUID, Name: cc.Name, TenantID: cc.TenantID, TenantName: cc.TenantName, ConsecutiveFailures: cc.ConsecutiveFailures,
		})
	}
	return out, nil
}

// PlatformListCronJobs · 跨租户 cron 列表 (后端分页 items+total)。
func (s *impl) PlatformListCronJobs(ctx context.Context, f PlatformCronListReq) (*PlatformCronListDTO, error) {
	rows, total, err := s.repo.PlatformListJobs(ctx, domcron.PlatformJobsFilter{
		TenantKeyword:          f.TenantKeyword,
		TaskKeyword:            f.TaskKeyword,
		Status:                 f.Status,
		LastResult:             f.LastResult,
		OnlyConsecutiveFailure: f.OnlyConsecutiveFailure,
		Limit:                  f.Limit,
		Offset:                 f.Offset,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if err := s.repo.FillJobDisplayMeta(ctx, rows); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "platform cron list: fill display meta failed", "err", err)
	}
	if err := s.repo.FillJobTenantNames(ctx, rows); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "platform cron list: fill tenant names failed", "err", err)
	}
	items := make([]PlatformCronJobDTO, 0, len(rows))
	for i := range rows {
		items = append(items, s.toPlatformJobDTO(&rows[i]))
	}
	return &PlatformCronListDTO{Items: items, Total: total}, nil
}

// AdminGetTenantJob · F25 返修：租户 admin 视角单任务详情 + 最近运行记录。
// 强制 tenantID 归属校验（跨租户 uuid 统一 not_found，不泄漏存在性）；
// 运行记录复用平台净化口径（状态/触发/耗时/错误摘要），不含 payload/rendered_prompt（F08 隐私决策）。
func (s *impl) AdminGetTenantJob(ctx context.Context, tenantID int64, jobUUID string, runLimit int) (*AdminTenantCronJobDetailDTO, error) {
	j, err := s.repo.GetJobByUUID(ctx, jobUUID)
	if err != nil {
		return nil, err
	}
	if j.TenantID != tenantID {
		return nil, apperr.ErrNotFound.Withf("cron.job_not_found")
	}
	jobs := []domcron.Job{*j}
	if err := s.repo.FillJobDisplayMeta(ctx, jobs); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "tenant cron detail: fill display meta failed", "err", err)
	}
	if runLimit <= 0 || runLimit > 50 {
		runLimit = 20
	}
	runs, err := s.repo.ListRuns(ctx, domcron.ListRunsFilter{
		TenantID:  j.TenantID,
		AccountID: j.AccountID,
		JobID:     j.ID,
		Limit:     runLimit,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	agentUUID := jobs[0].AgentUUID
	if agentUUID == "" {
		agentUUID, _ = s.fetchAgentUUID(ctx, jobs[0].AgentID)
	}
	jobDTO := s.toJobDTO(&jobs[0], agentUUID)
	jobDTO.Payload = nil // admin 视图不暴露 payload 详情（与 AdminListTenantJobs 同口径）
	jobDTO.OwnerDisplayName = jobs[0].OwnerDisplayName
	jobDTO.AgentName = jobs[0].AgentName
	out := &AdminTenantCronJobDetailDTO{
		Job:  jobDTO,
		Runs: make([]PlatformCronRunDTO, 0, len(runs)),
	}
	for i := range runs {
		out.Runs = append(out.Runs, PlatformCronRunDTO{
			UUID:         runs[i].UUID,
			Status:       runs[i].Status,
			TriggerKind:  runs[i].TriggerKind,
			StartedAt:    runs[i].StartedAt,
			FinishedAt:   runs[i].FinishedAt,
			DurationMs:   runs[i].DurationMs,
			ErrorMessage: runs[i].ErrorMessage,
			RetryCount:   runs[i].RetryCount,
		})
	}
	return out, nil
}

// PlatformGetCronJob · 单任务详情 + 最近运行记录 (跨租户读; job uuid 全局唯一)。
func (s *impl) PlatformGetCronJob(ctx context.Context, jobUUID string, runLimit int) (*PlatformCronJobDetailDTO, error) {
	j, err := s.repo.GetJobByUUID(ctx, jobUUID) // 不存在/软删 → apperr.ErrNotFound
	if err != nil {
		return nil, err
	}
	jobs := []domcron.Job{*j}
	if err := s.repo.FillJobDisplayMeta(ctx, jobs); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "platform cron detail: fill display meta failed", "err", err)
	}
	if err := s.repo.FillJobTenantNames(ctx, jobs); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "platform cron detail: fill tenant names failed", "err", err)
	}
	if runLimit <= 0 || runLimit > 50 {
		runLimit = 20
	}
	runs, err := s.repo.ListRuns(ctx, domcron.ListRunsFilter{
		TenantID:  j.TenantID,
		AccountID: j.AccountID,
		JobID:     j.ID,
		Limit:     runLimit,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := &PlatformCronJobDetailDTO{
		PlatformCronJobDTO: s.toPlatformJobDTO(&jobs[0]),
		Runs:               make([]PlatformCronRunDTO, 0, len(runs)),
	}
	for i := range runs {
		out.Runs = append(out.Runs, PlatformCronRunDTO{
			UUID:         runs[i].UUID,
			Status:       runs[i].Status,
			TriggerKind:  runs[i].TriggerKind,
			StartedAt:    runs[i].StartedAt,
			FinishedAt:   runs[i].FinishedAt,
			DurationMs:   runs[i].DurationMs,
			ErrorMessage: runs[i].ErrorMessage,
			RetryCount:   runs[i].RetryCount,
		})
	}
	return out, nil
}
