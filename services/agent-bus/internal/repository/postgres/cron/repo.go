// Package cron 是 M9 Agent 定时任务的 PG 仓储 (Phase A).
package cron

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	domcron "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/cron"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	repolocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/localruntime"
)

// Repo cron 仓储.
type Repo struct {
	pool      *pgxpool.Pool
	community bool
}

func New(pool *pgxpool.Pool) *Repo {
	if pool == nil {
		panic("cron.Repo: pool required")
	}
	return &Repo{pool: pool}
}

func (r *Repo) Pool() *pgxpool.Pool { return r.pool }

// jobCols · 所有 scan/RETURNING 共用列定义.
//
// L 增量: 加 delivery_kind / pause_reason / owner_inactive_at 三列;
// 之前 admin 列表拿不到 pause_reason 标签, 排查"为什么停了"必须看 audit log.
// 字段语义见 domain.Job 注释.
const jobCols = `id, uuid::text, tenant_id, account_id, agent_id, name, COALESCE(description,''),
        schedule_cron, timezone, payload, delivery, enabled, status, scheduler_kind,
        concurrent_policy, history_limit, consecutive_failures, failure_threshold,
        last_run_at, COALESCE(last_run_status,''), COALESCE(last_run_summary,''),
        next_run_at, metadata, created_at, updated_at,
        prompt_template_id, prompt_template_variables,
        COALESCE(delivery_kind,''), COALESCE(pause_reason,''), owner_inactive_at`

func scanJob(row pgx.Row) (*domcron.Job, error) {
	var j domcron.Job
	var payload, delivery, meta, tplVars []byte
	if err := row.Scan(&j.ID, &j.UUID, &j.TenantID, &j.AccountID, &j.AgentID, &j.Name, &j.Description,
		&j.ScheduleCron, &j.Timezone, &payload, &delivery, &j.Enabled, &j.Status, &j.SchedulerKind,
		&j.ConcurrentPolicy, &j.HistoryLimit, &j.ConsecutiveFailures, &j.FailureThreshold,
		&j.LastRunAt, &j.LastRunStatus, &j.LastRunSummary,
		&j.NextRunAt, &meta, &j.CreatedAt, &j.UpdatedAt,
		&j.PromptTemplateID, &tplVars,
		&j.DeliveryKind, &j.PauseReason, &j.OwnerInactiveAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	_ = json.Unmarshal(payload, &j.Payload)
	_ = json.Unmarshal(delivery, &j.Delivery)
	_ = json.Unmarshal(meta, &j.Metadata)
	_ = json.Unmarshal(tplVars, &j.PromptTemplateVariables)
	return &j, nil
}

// runtimeBindingCols · agent_cron_runtime_bindings 共用列.
const runtimeBindingCols = `id, uuid::text, cron_job_id, tenant_id, account_id, agent_id,
        runtime_environment_id, adapter_kind, framework, COALESCE(remote_job_id,''),
        desired_revision, remote_revision, sync_status, last_sync_error,
        last_synced_at, last_seen_at, source_snapshot, created_at, updated_at, deleted_at`

func scanRuntimeBinding(row pgx.Row) (*domcron.RuntimeBinding, error) {
	var b domcron.RuntimeBinding
	var snap []byte
	if err := row.Scan(&b.ID, &b.UUID, &b.CronJobID, &b.TenantID, &b.AccountID, &b.AgentID,
		&b.RuntimeEnvironmentID, &b.AdapterKind, &b.Framework, &b.RemoteJobID,
		&b.DesiredRevision, &b.RemoteRevision, &b.SyncStatus, &b.LastSyncError,
		&b.LastSyncedAt, &b.LastSeenAt, &snap, &b.CreatedAt, &b.UpdatedAt, &b.DeletedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	_ = json.Unmarshal(snap, &b.SourceSnapshot)
	return &b, nil
}

// CreateJob 同事务.
//
// M 返修: INSERT 必须显式写入 delivery_kind 列 (schema NOT NULL CHECK direct/group);
// 老实现漏写, 真实 DB insert 会被 PG 拒绝. service 必填 in.DeliveryKind.
func (r *Repo) CreateJob(ctx context.Context, tx pgx.Tx, in domcron.CreateJobInput) (*domcron.Job, error) {
	payload, _ := json.Marshal(in.Payload)
	if len(payload) == 0 {
		payload = []byte("{}")
	}
	delivery, _ := json.Marshal(in.Delivery)
	if len(delivery) == 0 {
		delivery = []byte("{}")
	}
	tplVars, _ := json.Marshal(in.PromptTemplateVariables)
	if len(tplVars) == 0 {
		tplVars = []byte("{}")
	}
	schedulerKind := strings.TrimSpace(in.SchedulerKind)
	if schedulerKind == "" {
		schedulerKind = domcron.SchedulerBus
	}
	metadata := []byte("{}")
	if in.RunOnce {
		metadata = []byte(`{"run_once":true}`)
	}
	row := tx.QueryRow(ctx,
		`INSERT INTO agent_cron_jobs (tenant_id, account_id, agent_id, name, description,
		    schedule_cron, timezone, payload, delivery, enabled, status, scheduler_kind,
		    concurrent_policy, history_limit, consecutive_failures, failure_threshold,
		    next_run_at, metadata, prompt_template_id, prompt_template_variables,
		    delivery_kind)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9::jsonb, true, 'active', $14,
		         'forbid', 100, 0, 3, $10, $15::jsonb, $11, $12::jsonb,
		         $13)
		 RETURNING `+jobCols,
		in.TenantID, in.AccountID, in.AgentID, in.Name, nullableString(in.Description),
		in.ScheduleCron, in.Timezone, payload, delivery, in.NextRunAt,
		in.PromptTemplateID, tplVars,
		in.DeliveryKind, schedulerKind, metadata,
	)
	return scanJob(row)
}

func (r *Repo) GetJobByUUID(ctx context.Context, uuid string) (*domcron.Job, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+jobCols+` FROM agent_cron_jobs
		  WHERE uuid=$1::uuid AND deleted_at IS NULL`, uuid)
	return scanJob(row)
}

func (r *Repo) GetJobByID(ctx context.Context, id int64) (*domcron.Job, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+jobCols+` FROM agent_cron_jobs
		  WHERE id=$1 AND deleted_at IS NULL`, id)
	return scanJob(row)
}

func (r *Repo) ListJobs(ctx context.Context, f domcron.ListJobsFilter) ([]domcron.Job, error) {
	limit := f.Limit
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	rows, err := r.pool.Query(ctx,
		`SELECT `+jobCols+` FROM agent_cron_jobs
		  WHERE tenant_id=$1 AND account_id=$2 AND deleted_at IS NULL
		  ORDER BY id DESC LIMIT $3`, f.TenantID, f.AccountID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]domcron.Job, 0, limit)
	for rows.Next() {
		j, err := scanJob(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *j)
	}
	return out, rows.Err()
}

// ListTenantJobs admin 视角: 列出本租户所有 job (不区分 owner).
func (r *Repo) ListTenantJobs(ctx context.Context, tenantID int64, limit int) ([]domcron.Job, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := r.pool.Query(ctx,
		`SELECT `+jobCols+` FROM agent_cron_jobs
		  WHERE tenant_id=$1 AND deleted_at IS NULL
		  ORDER BY id DESC LIMIT $2`, tenantID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domcron.Job{}
	for rows.Next() {
		j, err := scanJob(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *j)
	}
	return out, rows.Err()
}

// FillJobDisplayMeta · F08 §5.1 admin 列表显示名补充: 批量回填 AgentUUID / AgentName /
// OwnerDisplayName。两次 ANY() 批查 (≤500 行), 取代逐行 fetchAgentUUID 的 N 次远程往返。
// best-effort 语义: 查不到的行字段留空, 由调用方回退展示 id/uuid。
func (r *Repo) FillJobDisplayMeta(ctx context.Context, jobs []domcron.Job) error {
	if len(jobs) == 0 {
		return nil
	}
	agentIDs := make([]int64, 0, len(jobs))
	accountIDs := make([]int64, 0, len(jobs))
	seenAgent := map[int64]bool{}
	seenAccount := map[int64]bool{}
	for i := range jobs {
		if id := jobs[i].AgentID; id > 0 && !seenAgent[id] {
			seenAgent[id] = true
			agentIDs = append(agentIDs, id)
		}
		if id := jobs[i].AccountID; id > 0 && !seenAccount[id] {
			seenAccount[id] = true
			accountIDs = append(accountIDs, id)
		}
	}
	type agentMeta struct{ uuid, name string }
	agents := map[int64]agentMeta{}
	if len(agentIDs) > 0 {
		rows, err := r.pool.Query(ctx,
			`SELECT id, uuid::text, name FROM digital_employees WHERE id = ANY($1)`, agentIDs)
		if err != nil {
			return err
		}
		for rows.Next() {
			var id int64
			var u, n string
			if err := rows.Scan(&id, &u, &n); err != nil {
				rows.Close()
				return err
			}
			agents[id] = agentMeta{uuid: u, name: n}
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
	}
	owners := map[int64]string{}
	if len(accountIDs) > 0 {
		rows, err := r.pool.Query(ctx,
			`SELECT id, COALESCE(display_name,'') FROM accounts WHERE id = ANY($1)`, accountIDs)
		if err != nil {
			return err
		}
		for rows.Next() {
			var id int64
			var n string
			if err := rows.Scan(&id, &n); err != nil {
				rows.Close()
				return err
			}
			owners[id] = n
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
	}
	for i := range jobs {
		if m, ok := agents[jobs[i].AgentID]; ok {
			jobs[i].AgentUUID = m.uuid
			jobs[i].AgentName = m.name
		}
		if n, ok := owners[jobs[i].AccountID]; ok {
			jobs[i].OwnerDisplayName = n
		}
	}
	return nil
}

// CountActiveJobsForAccount · F08 §8.2 #7 / R7 v0.4.3 限额: 单 (tenant, account) active cron 数.
// active 口径: deleted_at IS NULL AND status != 'archived' (paused/error 都算占用名额).
// 用于 CreateJob 入口前的 ≤ DefaultAccountJobLimit (20) 校验.
func (r *Repo) CountActiveJobsForAccount(ctx context.Context, tenantID, accountID int64) (int, error) {
	var n int
	err := r.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM agent_cron_jobs
		  WHERE tenant_id=$1 AND account_id=$2
		    AND deleted_at IS NULL
		    AND status <> 'archived'`, tenantID, accountID).Scan(&n)
	return n, err
}

// CountActiveJobsForTenant · F08 §8.2 #7 / R7 v0.4.3 限额: 单 tenant active cron 数.
// active 口径同 CountActiveJobsForAccount.
// 用于 CreateJob 入口前的 ≤ DefaultTenantJobLimit (500) 校验.
func (r *Repo) CountActiveJobsForTenant(ctx context.Context, tenantID int64) (int, error) {
	var n int
	err := r.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM agent_cron_jobs
		  WHERE tenant_id=$1
		    AND deleted_at IS NULL
		    AND status <> 'archived'`, tenantID).Scan(&n)
	return n, err
}

// BulkPauseForOwnerInactive · F08 §4.4 / R10 · owner suspended/left 时一次性停掉该 (tenant, account)
// 名下所有 active cron.
//
// 一次性 UPDATE:
//   - status='paused' + enabled=false + pause_reason='owner_inactive' + owner_inactive_at=now()
//   - 只命中 deleted_at IS NULL + status='active' (跳过已 paused/error/archived)
//
// 返回受影响行数, 用于 listener emit audit + admin SSE 计数.
// **不**做移交, **不**做 30 天 archive (F08 v0.4.3 决议).
func (r *Repo) BulkPauseForOwnerInactive(ctx context.Context, tx pgx.Tx, tenantID, accountID int64, now time.Time) (int, error) {
	var tag pgconn.CommandTag
	var err error
	sql := `UPDATE agent_cron_jobs
	          SET status='paused', enabled=false,
	              pause_reason='owner_inactive', owner_inactive_at=$1, updated_at=$1
	        WHERE tenant_id=$2 AND account_id=$3
	          AND deleted_at IS NULL AND status='active'`
	if tx != nil {
		tag, err = tx.Exec(ctx, sql, now, tenantID, accountID)
	} else {
		tag, err = r.pool.Exec(ctx, sql, now, tenantID, accountID)
	}
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

// ListEnabledJobs · admin dry-run 用: 拉全平台 enabled cron job (含跨租户),
// 仅本进程使用; 走过滤的下游再按 capability 校验是否违例.
// limit 最大 5000 (一次扫表上限).
func (r *Repo) ListEnabledJobs(ctx context.Context, limit int) ([]domcron.Job, error) {
	if limit <= 0 || limit > 5000 {
		limit = 1000
	}
	rows, err := r.pool.Query(ctx,
		`SELECT `+jobCols+` FROM agent_cron_jobs
		  WHERE deleted_at IS NULL AND enabled=true
		  ORDER BY id ASC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domcron.Job{}
	for rows.Next() {
		j, err := scanJob(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *j)
	}
	return out, rows.Err()
}

// GetRuntimeBindingByRemoteJobID finds an active projection binding by runtime job id.
func (r *Repo) GetRuntimeBindingByRemoteJobID(ctx context.Context, adapterKind, remoteJobID string) (*domcron.RuntimeBinding, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+runtimeBindingCols+`
		   FROM agent_cron_runtime_bindings
		  WHERE adapter_kind=$1 AND remote_job_id=$2 AND deleted_at IS NULL
		  ORDER BY id DESC LIMIT 1`,
		adapterKind, remoteJobID)
	return scanRuntimeBinding(row)
}

// GetRuntimeBindingByJob finds the active projection binding for a job/runtime/adapter.
func (r *Repo) GetRuntimeBindingByJob(ctx context.Context, jobID, runtimeEnvID int64, adapterKind string) (*domcron.RuntimeBinding, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+runtimeBindingCols+`
		   FROM agent_cron_runtime_bindings
		  WHERE cron_job_id=$1 AND runtime_environment_id=$2 AND adapter_kind=$3 AND deleted_at IS NULL
		  ORDER BY id DESC LIMIT 1`,
		jobID, runtimeEnvID, adapterKind)
	return scanRuntimeBinding(row)
}

// UpsertRuntimeBinding records the latest desired-state projection status.
func (r *Repo) UpsertRuntimeBinding(ctx context.Context, in domcron.UpsertRuntimeBindingInput) (*domcron.RuntimeBinding, error) {
	snap, _ := json.Marshal(in.SourceSnapshot)
	if len(snap) == 0 {
		snap = []byte("{}")
	}
	status := strings.TrimSpace(in.SyncStatus)
	if status == "" {
		status = domcron.RuntimeSyncPending
	}
	remoteID := strings.TrimSpace(in.RemoteJobID)
	if remoteID != "" {
		row := r.pool.QueryRow(ctx,
			`INSERT INTO agent_cron_runtime_bindings (
			    cron_job_id, tenant_id, account_id, agent_id, runtime_environment_id,
			    adapter_kind, framework, remote_job_id, desired_revision, remote_revision,
			    sync_status, last_sync_error, last_synced_at, source_snapshot)
			 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14::jsonb)
			 ON CONFLICT (adapter_kind, remote_job_id)
			 WHERE deleted_at IS NULL AND remote_job_id IS NOT NULL AND remote_job_id <> ''
			 DO UPDATE SET
			    framework=EXCLUDED.framework,
			    desired_revision=EXCLUDED.desired_revision,
			    remote_revision=EXCLUDED.remote_revision,
			    sync_status=EXCLUDED.sync_status,
			    last_sync_error=EXCLUDED.last_sync_error,
			    last_synced_at=EXCLUDED.last_synced_at,
			    last_seen_at=CASE WHEN EXCLUDED.sync_status='synced' THEN now() ELSE agent_cron_runtime_bindings.last_seen_at END,
			    source_snapshot=EXCLUDED.source_snapshot,
			    updated_at=now()
			 RETURNING `+runtimeBindingCols,
			in.CronJobID, in.TenantID, in.AccountID, in.AgentID, in.RuntimeEnvironmentID,
			in.AdapterKind, in.Framework, remoteID, in.DesiredRevision, in.RemoteRevision,
			status, in.LastSyncError, in.LastSyncedAt, snap)
		return scanRuntimeBinding(row)
	}
	row := r.pool.QueryRow(ctx,
		`INSERT INTO agent_cron_runtime_bindings (
		    cron_job_id, tenant_id, account_id, agent_id, runtime_environment_id,
		    adapter_kind, framework, remote_job_id, desired_revision, remote_revision,
		    sync_status, last_sync_error, last_synced_at, source_snapshot)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,NULLIF($8,''),$9,$10,$11,$12,$13,$14::jsonb)
		 ON CONFLICT (cron_job_id, runtime_environment_id, adapter_kind) WHERE deleted_at IS NULL
		 DO UPDATE SET
		    tenant_id=EXCLUDED.tenant_id,
		    account_id=EXCLUDED.account_id,
		    agent_id=EXCLUDED.agent_id,
		    framework=EXCLUDED.framework,
		    remote_job_id=COALESCE(EXCLUDED.remote_job_id, agent_cron_runtime_bindings.remote_job_id),
		    desired_revision=EXCLUDED.desired_revision,
		    remote_revision=EXCLUDED.remote_revision,
		    sync_status=EXCLUDED.sync_status,
		    last_sync_error=EXCLUDED.last_sync_error,
		    last_synced_at=EXCLUDED.last_synced_at,
		    last_seen_at=CASE WHEN EXCLUDED.sync_status='synced' THEN now() ELSE agent_cron_runtime_bindings.last_seen_at END,
		    source_snapshot=EXCLUDED.source_snapshot,
		    updated_at=now()
		 RETURNING `+runtimeBindingCols,
		in.CronJobID, in.TenantID, in.AccountID, in.AgentID, in.RuntimeEnvironmentID,
		in.AdapterKind, in.Framework, in.RemoteJobID, in.DesiredRevision, in.RemoteRevision,
		status, in.LastSyncError, in.LastSyncedAt, snap)
	return scanRuntimeBinding(row)
}

// SoftDeleteRuntimeBindingByJob marks all active projection bindings for a cron job deleted.
func (r *Repo) SoftDeleteRuntimeBindingByJob(ctx context.Context, jobID int64) error {
	_, err := r.pool.Exec(ctx,
		`UPDATE agent_cron_runtime_bindings
		    SET sync_status='deleting', deleted_at=now(), updated_at=now()
		  WHERE cron_job_id=$1 AND deleted_at IS NULL`, jobID)
	return err
}

// ListRuntimeBindingsForRetry returns active projection bindings that need reconcile.
func (r *Repo) ListRuntimeBindingsForRetry(ctx context.Context, limit int) ([]domcron.RuntimeBinding, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	rows, err := r.pool.Query(ctx,
		`SELECT `+runtimeBindingCols+`
		   FROM agent_cron_runtime_bindings
		  WHERE deleted_at IS NULL
		    AND sync_status IN ('pending','error','drift')
		    AND EXISTS (SELECT 1 FROM agent_cron_jobs j
		                WHERE j.id=agent_cron_runtime_bindings.cron_job_id
		                  AND j.deleted_at IS NULL)
		  ORDER BY updated_at ASC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]domcron.RuntimeBinding, 0, limit)
	for rows.Next() {
		b, err := scanRuntimeBinding(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *b)
	}
	return out, rows.Err()
}

// PatchJob 同事务. 不更新 schedule_cron / timezone / payload / delivery / next_run_at
// 时这些参数留 nil. metadata 通过 ClearAdminFlag / SetAdminFlag 影响.
func (r *Repo) PatchJob(ctx context.Context, tx pgx.Tx, jobID int64, in domcron.PatchJobInput) error {
	sets := ""
	args := []any{jobID}
	idx := 2
	if in.Name != nil {
		sets += ", name=$" + itoa(idx)
		args = append(args, *in.Name)
		idx++
	}
	if in.Description != nil {
		sets += ", description=$" + itoa(idx)
		args = append(args, *in.Description)
		idx++
	}
	if in.ScheduleCron != nil {
		sets += ", schedule_cron=$" + itoa(idx)
		args = append(args, *in.ScheduleCron)
		idx++
	}
	if in.Timezone != nil {
		sets += ", timezone=$" + itoa(idx)
		args = append(args, *in.Timezone)
		idx++
	}
	if in.Payload != nil {
		body, _ := json.Marshal(in.Payload)
		sets += ", payload=$" + itoa(idx) + "::jsonb"
		args = append(args, body)
		idx++
	}
	if in.Delivery != nil {
		body, _ := json.Marshal(in.Delivery)
		sets += ", delivery=$" + itoa(idx) + "::jsonb"
		args = append(args, body)
		idx++
	}
	if in.Enabled != nil {
		sets += ", enabled=$" + itoa(idx)
		args = append(args, *in.Enabled)
		idx++
	}
	if in.Status != nil {
		sets += ", status=$" + itoa(idx)
		args = append(args, *in.Status)
		idx++
	}
	if in.SchedulerKind != nil {
		sets += ", scheduler_kind=$" + itoa(idx)
		args = append(args, *in.SchedulerKind)
		idx++
	}
	if in.NextRunAt != nil {
		sets += ", next_run_at=$" + itoa(idx)
		args = append(args, *in.NextRunAt)
		idx++
	}
	if in.ResetFailures {
		sets += ", consecutive_failures=0"
	}
	if in.IncFailures {
		sets += ", consecutive_failures=consecutive_failures+1"
	}
	if in.SetAdminFlag {
		// metadata = jsonb_set(metadata, '{admin_disabled}', 'true')
		sets += ", metadata=jsonb_set(COALESCE(metadata,'{}'::jsonb), '{admin_disabled}', 'true'::jsonb, true)"
	}
	if in.ClearAdminFlag {
		sets += ", metadata=metadata - 'admin_disabled'"
	}
	if in.SetRunOnce != nil {
		if *in.SetRunOnce {
			sets += ", metadata=jsonb_set(COALESCE(metadata,'{}'::jsonb), '{run_once}', 'true'::jsonb, true)"
		} else {
			sets += ", metadata=metadata - 'run_once'"
		}
	}
	// M 返修 · F08 R4 · delivery_kind 列同步 (PatchJob 改 conversation_uuid 时).
	if in.DeliveryKind != nil {
		sets += ", delivery_kind=$" + itoa(idx)
		args = append(args, *in.DeliveryKind)
		idx++
	}
	// M 返修 · F08 R6/R10 · pause_reason 列同步. SET / NULL 二选一; 若 caller 同时
	// 设 PauseReason + ClearPauseReason, ClearPauseReason 不生效 (SET 优先).
	if in.PauseReason != nil {
		sets += ", pause_reason=$" + itoa(idx)
		args = append(args, *in.PauseReason)
		idx++
	} else if in.ClearPauseReason {
		sets += ", pause_reason=NULL"
	}
	if in.SetLastRun != nil {
		sets += ", last_run_at=$" + itoa(idx)
		args = append(args, in.SetLastRun.At)
		idx++
		sets += ", last_run_status=$" + itoa(idx)
		args = append(args, in.SetLastRun.Status)
		idx++
		sets += ", last_run_summary=$" + itoa(idx)
		args = append(args, in.SetLastRun.Summary)
		idx++
	}
	if in.SetPromptTemplate {
		// R9: in.PromptTemplateID 可 nil 表示清掉模板退回老 payload 路径.
		sets += ", prompt_template_id=$" + itoa(idx)
		args = append(args, in.PromptTemplateID)
		idx++
	}
	if in.PromptTemplateVariables != nil {
		body, _ := json.Marshal(in.PromptTemplateVariables)
		sets += ", prompt_template_variables=$" + itoa(idx) + "::jsonb"
		args = append(args, body)
		idx++
	}
	if sets == "" {
		return nil
	}
	sql := `UPDATE agent_cron_jobs SET updated_at=now()` + sets + ` WHERE id=$1 AND deleted_at IS NULL`
	tag, err := tx.Exec(ctx, sql, args...)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

// SoftDeleteJob 同事务软删.
func (r *Repo) SoftDeleteJob(ctx context.Context, tx pgx.Tx, jobID int64) error {
	tag, err := tx.Exec(ctx,
		`UPDATE agent_cron_jobs SET deleted_at=now(), updated_at=now()
		  WHERE id=$1 AND deleted_at IS NULL`, jobID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

// DueJobs cron worker 30s 扫描入口.
// 返回 enabled=true AND status='active' AND scheduler_kind='bus'
//
//	AND next_run_at IS NOT NULL AND next_run_at <= horizon.
func (r *Repo) DueJobs(ctx context.Context, horizon time.Time, limit int) ([]domcron.Job, error) {
	if limit <= 0 {
		limit = 50
	}
	rows, err := r.pool.Query(ctx,
		`SELECT `+jobCols+` FROM agent_cron_jobs
		  WHERE deleted_at IS NULL AND enabled=true AND status='active'
		    AND scheduler_kind='bus'
		    AND next_run_at IS NOT NULL AND next_run_at <= $1
            AND `+r.desktopReadySQL("agent_cron_jobs")+`
		  ORDER BY next_run_at ASC LIMIT $2`, horizon, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domcron.Job{}
	for rows.Next() {
		j, err := scanJob(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *j)
	}
	return out, rows.Err()
}

// HasActiveRun 看是否已有 queued / running run (concurrent_policy='forbid' 时跳过).
func (r *Repo) HasActiveRun(ctx context.Context, jobID int64) (bool, error) {
	var n int
	err := r.pool.QueryRow(ctx,
		`SELECT 1 FROM agent_cron_runs
		  WHERE job_id=$1 AND status IN ('queued','running')
		  LIMIT 1`, jobID).Scan(&n)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// =====================================================
// cron_dispatch_locks
// =====================================================

// AcquireLock 抢锁: INSERT 或 UPDATE expires_at<now() 的过期行.
// 返回 acquired=true 表示本节点抢到; false 表示其他节点持有.
func (r *Repo) AcquireLock(ctx context.Context, jobID int64, nodeID string, ttl time.Duration) (bool, error) {
	now := time.Now()
	expires := now.Add(ttl)
	// Postgres 9.5+: INSERT ... ON CONFLICT (job_id) DO UPDATE WHERE existing.expires_at <= now().
	tag, err := r.pool.Exec(ctx,
		`INSERT INTO cron_dispatch_locks (job_id, locked_by, locked_at, expires_at)
		 VALUES ($1, $2, $3, $4)
		 ON CONFLICT (job_id) DO UPDATE
		   SET locked_by = EXCLUDED.locked_by,
		       locked_at = EXCLUDED.locked_at,
		       expires_at = EXCLUDED.expires_at
		   WHERE cron_dispatch_locks.expires_at <= $3`,
		jobID, nodeID, now, expires)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

func (r *Repo) ReleaseLock(ctx context.Context, jobID int64, nodeID string) error {
	_, err := r.pool.Exec(ctx,
		`DELETE FROM cron_dispatch_locks WHERE job_id=$1 AND locked_by=$2`, jobID, nodeID)
	return err
}

// =====================================================
// agent_cron_runs
// =====================================================

const runCols = `id, uuid::text, job_id, tenant_id, account_id, agent_id,
        conversation_id, COALESCE(message_uuid::text,''),
        started_at, finished_at, status, COALESCE(duration_ms,0),
        COALESCE(summary,''), COALESCE(error_message,''),
        COALESCE(trigger_kind,''), COALESCE(retry_count,0), COALESCE(trace_id,''),
        payload_snapshot, created_at,
        COALESCE(rendered_prompt_snapshot,'')`

func scanRun(row pgx.Row) (*domcron.Run, error) {
	var rn domcron.Run
	var payload []byte
	if err := row.Scan(&rn.ID, &rn.UUID, &rn.JobID, &rn.TenantID, &rn.AccountID, &rn.AgentID,
		&rn.ConversationID, &rn.MessageUUID,
		&rn.StartedAt, &rn.FinishedAt, &rn.Status, &rn.DurationMs,
		&rn.Summary, &rn.ErrorMessage,
		&rn.TriggerKind, &rn.RetryCount, &rn.TraceID,
		&payload, &rn.CreatedAt,
		&rn.RenderedPromptSnapshot); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	_ = json.Unmarshal(payload, &rn.PayloadSnapshot)
	return &rn, nil
}

func (r *Repo) CreateRun(ctx context.Context, tx pgx.Tx, in domcron.CreateRunInput) (*domcron.Run, error) {
	body, _ := json.Marshal(in.PayloadSnapshot)
	if len(body) == 0 {
		body = []byte("{}")
	}
	row := tx.QueryRow(ctx,
		`INSERT INTO agent_cron_runs (job_id, tenant_id, account_id, agent_id, status,
		    payload_snapshot, trigger_kind, retry_count, trace_id)
		 VALUES ($1, $2, $3, $4, 'queued', $5::jsonb, $6, 0, $7)
		 RETURNING `+runCols,
		in.JobID, in.TenantID, in.AccountID, in.AgentID, body,
		nullableString(in.TriggerKind), nullableString(in.TraceID))
	return scanRun(row)
}

func (r *Repo) GetRunByUUID(ctx context.Context, uuid string) (*domcron.Run, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+runCols+` FROM agent_cron_runs WHERE uuid=$1::uuid`, uuid)
	return scanRun(row)
}

func (r *Repo) UpdateRun(ctx context.Context, tx pgx.Tx, runID int64, in domcron.UpdateRunInput) error {
	sets := ""
	args := []any{runID}
	idx := 2
	if in.Status != nil {
		sets += ", status=$" + itoa(idx)
		args = append(args, *in.Status)
		idx++
	}
	if in.FinishedAt != nil {
		sets += ", finished_at=$" + itoa(idx)
		args = append(args, *in.FinishedAt)
		idx++
	}
	if in.DurationMs != nil {
		sets += ", duration_ms=$" + itoa(idx)
		args = append(args, *in.DurationMs)
		idx++
	}
	if in.Summary != nil {
		sets += ", summary=$" + itoa(idx)
		args = append(args, *in.Summary)
		idx++
	}
	if in.ErrorMessage != nil {
		sets += ", error_message=$" + itoa(idx)
		args = append(args, *in.ErrorMessage)
		idx++
	}
	if in.ConversationID != nil {
		sets += ", conversation_id=$" + itoa(idx)
		args = append(args, *in.ConversationID)
		idx++
	}
	if in.MessageUUID != nil {
		sets += ", message_uuid=$" + itoa(idx) + "::uuid"
		args = append(args, *in.MessageUUID)
		idx++
	}
	if in.RenderedPromptSnapshot != nil {
		sets += ", rendered_prompt_snapshot=$" + itoa(idx)
		args = append(args, *in.RenderedPromptSnapshot)
		idx++
	}
	if sets == "" {
		return nil
	}
	// 用 leading 的预留赋值避免 "UPDATE ... SET , status=..." 语法错; updated_at 字段在
	// agent_cron_runs 上不存在, 改用 trigger_kind=trigger_kind 这种自更.
	sql := `UPDATE agent_cron_runs SET trigger_kind=trigger_kind` + sets + ` WHERE id=$1`
	_, err := tx.Exec(ctx, sql, args...)
	return err
}

func (r *Repo) ListRuns(ctx context.Context, f domcron.ListRunsFilter) ([]domcron.Run, error) {
	limit := f.Limit
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	args := []any{f.TenantID, f.AccountID}
	where := `WHERE tenant_id=$1 AND account_id=$2`
	idx := 3
	if f.JobID > 0 {
		where += " AND job_id=$" + strconv.Itoa(idx)
		args = append(args, f.JobID)
		idx++
	}
	if f.Status != "" {
		where += " AND status=$" + strconv.Itoa(idx)
		args = append(args, f.Status)
		idx++
	}
	if f.BeforeUUID != "" {
		where += " AND id < (SELECT id FROM agent_cron_runs WHERE uuid=$" + strconv.Itoa(idx) + "::uuid)"
		args = append(args, f.BeforeUUID)
		idx++
	}
	where += " ORDER BY id DESC LIMIT $" + strconv.Itoa(idx)
	args = append(args, limit)
	rows, err := r.pool.Query(ctx, `SELECT `+runCols+` FROM agent_cron_runs `+where, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domcron.Run{}
	for rows.Next() {
		rn, err := scanRun(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *rn)
	}
	return out, rows.Err()
}

// ReapStaleRunningRuns Codex P1#3: 把 started_at < cutoff 的 running run 全部标 failed.
//
// 防 bus executor 崩溃后 running run 永久卡住, 让 concurrent_policy=forbid 的下次触发
// 卡死. 返回受影响行 (caller 用来写 audit + SSE).
//
// 调用方应在 DispatchTick 前调用, 频率与 dispatcher 同 (30s).
func (r *Repo) ReapStaleRunningRuns(ctx context.Context, cutoff time.Time, errCode string) ([]domcron.Run, error) {
	// 1) 先 SELECT 出受影响行 (含 job_id, tenant_id 等元数据), 然后 UPDATE.
	//    用同事务保证 SELECT/UPDATE 的 row set 一致.
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	rows, err := tx.Query(ctx,
		`SELECT `+runCols+` FROM agent_cron_runs
		  WHERE status='running' AND started_at < $1
		  FOR UPDATE SKIP LOCKED`, cutoff)
	if err != nil {
		return nil, err
	}
	stale := []domcron.Run{}
	for rows.Next() {
		rn, err := scanRun(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		stale = append(stale, *rn)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(stale) == 0 {
		_ = tx.Commit(ctx)
		return nil, nil
	}
	now := time.Now()
	for i := range stale {
		dur := now.Sub(stale[i].StartedAt).Milliseconds()
		if _, err := tx.Exec(ctx,
			`UPDATE agent_cron_runs
			    SET status='failed', finished_at=$2, duration_ms=$3, error_message=$4
			  WHERE id=$1`,
			stale[i].ID, now, dur, errCode); err != nil {
			return nil, err
		}
		stale[i].Status = domcron.RunStatusFailed
		stale[i].FinishedAt = &now
		stale[i].DurationMs = dur
		stale[i].ErrorMessage = errCode
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return stale, nil
}

// PickQueuedRunForUpdate executor 拉一行 queued run, 用 SKIP LOCKED 避免多副本竞争.
// 同事务把 status 升到 'running' + started_at=now.
func (r *Repo) PickQueuedRunForUpdate(ctx context.Context, tx pgx.Tx, limit int) ([]domcron.Run, error) {
	if limit <= 0 {
		limit = 5
	}
	rows, err := tx.Query(ctx,
		`SELECT `+runCols+` FROM agent_cron_runs
		  WHERE status='queued' AND (
            EXISTS (SELECT 1 FROM agent_cron_jobs j WHERE j.id=agent_cron_runs.job_id AND (j.deleted_at IS NOT NULL OR j.status<>'active'))
            OR `+r.desktopReadySQL("agent_cron_runs")+`)
		  ORDER BY id ASC
		  FOR UPDATE SKIP LOCKED
		  LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domcron.Run{}
	for rows.Next() {
		rn, err := scanRun(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *rn)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// 升 running.
	for i := range out {
		if err := tx.QueryRow(ctx,
			`UPDATE agent_cron_runs SET status='running', started_at=now() WHERE id=$1 RETURNING started_at`, out[i].ID).Scan(&out[i].StartedAt); err != nil {
			return nil, err
		}
		out[i].Status = "running"
	}
	return out, nil
}

// =====================================================
// F08 §8.2 #4 / R9 · cron_prompt_templates 读取 (Phase A 只用读, CRUD 走 admin)
// =====================================================

// promptTplCols · 公共列定义, ByUUID / ByID / List / Create / RETURNING 共用 scan 字段顺序.
//
// J 返修: 加 COALESCE(description,”) 列; 老 schema 的 description 列可空, 早期 model 没读
// 这一列, admin 编辑 drawer 拿不回 description → PATCH 空 state 把 description 抹空.
//
// K 增量: 加 created_at / updated_at 列, admin 列表需要展示"上次更新时间".
const promptTplCols = `id, uuid::text, scope_kind, tenant_id, code, name,
        COALESCE(description, '') AS description, template_body, is_system, status,
        created_at, updated_at`

func scanPromptTemplate(row pgx.Row) (*domcron.PromptTemplate, error) {
	var t domcron.PromptTemplate
	if err := row.Scan(&t.ID, &t.UUID, &t.ScopeKind, &t.TenantID, &t.Code, &t.Name,
		&t.Description, &t.TemplateBody, &t.IsSystem, &t.Status,
		&t.CreatedAt, &t.UpdatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return &t, nil
}

// GetPromptTemplateByUUID · R9 · 查模板 + 校 is_deleted=false (不过滤 status,
// 让 service 层判 archived 等情况, 错误码语义更清).
//
// 不带 scope 过滤; service 层根据 caller tenant 自己拦"看见的范围"
// (scope='platform' 或 scope='tenant' AND tenant_id=caller).
func (r *Repo) GetPromptTemplateByUUID(ctx context.Context, uuid string) (*domcron.PromptTemplate, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+promptTplCols+`
		   FROM cron_prompt_templates
		  WHERE uuid=$1::uuid AND is_deleted=false`, uuid)
	return scanPromptTemplate(row)
}

// GetPromptTemplateByID · E4 / R9 · runtime executor 拿到 job.PromptTemplateID (int64)
// 时反查模板; service 层不再直拼 SQL 走 pool.
//
// 失败 / 不存在 / 已软删 → ErrNotFound; 调用方决定如何把它转成 cron.prompt_template_not_found.
func (r *Repo) GetPromptTemplateByID(ctx context.Context, id int64) (*domcron.PromptTemplate, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+promptTplCols+`
		   FROM cron_prompt_templates
		  WHERE id=$1 AND is_deleted=false`, id)
	return scanPromptTemplate(row)
}

// ListAdminTenantPromptTemplates · G4 / F08 §5.2 · admin 视角列表.
//
// admin 视角放宽于 client (ListVisiblePromptTemplates):
//   - tenant 模板: tenant_id=caller AND is_deleted=false (含 draft / active / archived).
//   - platform 模板: is_deleted=false AND status='active' (只读, 不展示 draft).
//
// 排序: platform 先, 同 scope 内按 code ASC.
func (r *Repo) ListAdminTenantPromptTemplates(ctx context.Context, tenantID int64, limit int) ([]domcron.PromptTemplate, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := r.pool.Query(ctx,
		`SELECT `+promptTplCols+`
		   FROM cron_prompt_templates
		  WHERE is_deleted=false
		    AND (
		         (scope_kind='platform' AND status='active')
		      OR (scope_kind='tenant'   AND tenant_id=$1)
		    )
		  ORDER BY scope_kind ASC, code ASC
		  LIMIT $2`, tenantID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domcron.PromptTemplate{}
	for rows.Next() {
		t, err := scanPromptTemplate(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *t)
	}
	return out, rows.Err()
}

// CreateTenantPromptTemplate · G4 · scope='tenant' 强制由 service 决定; repo 直接落.
// (scope, tenant_id, code) 唯一冲突由 PG 抛 unique_violation, 调用方转业务错误码.
func (r *Repo) CreateTenantPromptTemplate(ctx context.Context, tx pgx.Tx, in domcron.CreatePromptTemplateInput) (*domcron.PromptTemplate, error) {
	status := strings.TrimSpace(in.Status)
	if status == "" {
		status = domcron.TemplateStatusActive
	}
	row := tx.QueryRow(ctx,
		`INSERT INTO cron_prompt_templates (scope_kind, tenant_id, code, name, description,
		    template_body, is_system, status, created_by, updated_by)
		 VALUES ('tenant', $1, $2, $3, $4, $5, false, $6, $7, $7)
		 RETURNING `+promptTplCols,
		in.TenantID, in.Code, in.Name, nullableString(in.Description),
		in.TemplateBody, status, in.CreatedBy,
	)
	tpl, err := scanPromptTemplate(row)
	if err != nil {
		return nil, err
	}
	if len(in.Variables) > 0 {
		if err := r.insertVariablesTx(ctx, tx, tpl.ID, in.CreatedBy, in.Variables); err != nil {
			return nil, err
		}
	}
	return tpl, nil
}

// ListAdminPlatformPromptTemplates · 平台控制台视角: scope='platform' 全状态
// (draft/active/archived), 排软删. 租户/客户端读路径不变 (仍只消费 active)。
func (r *Repo) ListAdminPlatformPromptTemplates(ctx context.Context, limit int) ([]domcron.PromptTemplate, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := r.pool.Query(ctx,
		`SELECT `+promptTplCols+`
		   FROM cron_prompt_templates
		  WHERE is_deleted=false AND scope_kind='platform'
		  ORDER BY code ASC
		  LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domcron.PromptTemplate{}
	for rows.Next() {
		t, err := scanPromptTemplate(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *t)
	}
	return out, rows.Err()
}

// CreatePlatformPromptTemplate · 平台模板 INSERT (scope='platform', tenant_id NULL,
// 见表 CHECK 约束)。code 唯一由部分索引 uq_cron_prompt_tpl_platform_code 保证,
// 冲突由 PG 抛 unique_violation, 调用方转业务错误码。
// is_system 固定 false: 该标记保留给"内置不可删"种子, 平台超管自建模板可改可删。
func (r *Repo) CreatePlatformPromptTemplate(ctx context.Context, tx pgx.Tx, in domcron.CreatePromptTemplateInput) (*domcron.PromptTemplate, error) {
	status := strings.TrimSpace(in.Status)
	if status == "" {
		status = domcron.TemplateStatusActive
	}
	row := tx.QueryRow(ctx,
		`INSERT INTO cron_prompt_templates (scope_kind, tenant_id, code, name, description,
		    template_body, is_system, status, created_by, updated_by)
		 VALUES ('platform', NULL, $1, $2, $3, $4, false, $5, $6, $6)
		 RETURNING `+promptTplCols,
		in.Code, in.Name, nullableString(in.Description),
		in.TemplateBody, status, in.CreatedBy,
	)
	tpl, err := scanPromptTemplate(row)
	if err != nil {
		return nil, err
	}
	if len(in.Variables) > 0 {
		if err := r.insertVariablesTx(ctx, tx, tpl.ID, in.CreatedBy, in.Variables); err != nil {
			return nil, err
		}
	}
	return tpl, nil
}

// insertVariablesTx · 内部 helper: 批量写 variables (在 tx 内).
func (r *Repo) insertVariablesTx(ctx context.Context, tx pgx.Tx, templateID, createdBy int64, vars []domcron.PromptTemplateVariable) error {
	for _, v := range vars {
		defaultJSON, _ := json.Marshal(v.DefaultValue)
		optsJSON, _ := json.Marshal(v.Options)
		if v.Options == nil {
			optsJSON = nil
		}
		if v.DefaultValue == nil {
			defaultJSON = nil
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO cron_prompt_template_variables (template_id, var_name, var_type, required,
			    default_value, options, display_name, order_index, created_by, updated_by)
			 VALUES ($1, $2, $3, $4, $5::jsonb, $6::jsonb, $7, $8, $9, $9)`,
			templateID, v.VarName, v.VarType, v.Required,
			defaultJSON, optsJSON, nullableString(v.DisplayName), v.OrderIndex, createdBy,
		); err != nil {
			return err
		}
	}
	return nil
}

// PatchAdminPromptTemplate · G4 · 按字段更新; 调用方负责 is_system / scope 拒绝判断.
//
// ReplaceVars=true 时按 Variables 全量替换 (含清空).
func (r *Repo) PatchAdminPromptTemplate(ctx context.Context, tx pgx.Tx, templateID int64, in domcron.PatchPromptTemplateInput) error {
	sets := ""
	args := []any{templateID}
	idx := 2
	if in.Name != nil {
		sets += ", name=$" + itoa(idx)
		args = append(args, *in.Name)
		idx++
	}
	if in.Description != nil {
		sets += ", description=$" + itoa(idx)
		args = append(args, *in.Description)
		idx++
	}
	if in.TemplateBody != nil {
		sets += ", template_body=$" + itoa(idx)
		args = append(args, *in.TemplateBody)
		idx++
	}
	if in.Status != nil {
		sets += ", status=$" + itoa(idx)
		args = append(args, *in.Status)
		idx++
	}
	sets += ", updated_by=$" + itoa(idx)
	args = append(args, in.UpdatedBy)
	idx++
	if sets != "" {
		sql := `UPDATE cron_prompt_templates SET updated_at=now()` + sets +
			` WHERE id=$1 AND is_deleted=false`
		tag, err := tx.Exec(ctx, sql, args...)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.ErrNotFound
		}
	}
	if in.ReplaceVars {
		if _, err := tx.Exec(ctx,
			`DELETE FROM cron_prompt_template_variables WHERE template_id=$1`, templateID); err != nil {
			return err
		}
		if err := r.insertVariablesTx(ctx, tx, templateID, in.UpdatedBy, in.Variables); err != nil {
			return err
		}
	}
	return nil
}

// SoftDeletePromptTemplate · G4 · 软删 (是否被引用由 service 层 CountActiveJobsUsingTemplate 拦截).
func (r *Repo) SoftDeletePromptTemplate(ctx context.Context, tx pgx.Tx, templateID int64) error {
	tag, err := tx.Exec(ctx,
		`UPDATE cron_prompt_templates
		    SET is_deleted=true, deleted_at=now(), updated_at=now()
		  WHERE id=$1 AND is_deleted=false`, templateID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

// CountActiveJobsUsingTemplate · G4 · 删模板前拦"还在被 cron 引用"的情况.
//
// active 口径: deleted_at IS NULL (job 软删后视为不再引用).
// **不**按 tenant 过滤 — 删除校验是 "全平台还有没有人引用", 跨 tenant 也算.
// admin 列表展示的"本租户引用数"走 CountActiveJobsByTemplateIDs (按 tenant 过滤).
func (r *Repo) CountActiveJobsUsingTemplate(ctx context.Context, templateID int64) (int, error) {
	var n int
	err := r.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM agent_cron_jobs
		  WHERE prompt_template_id=$1 AND deleted_at IS NULL`, templateID).Scan(&n)
	return n, err
}

// CountActiveJobsByTemplateIDs · K · admin 列表用的批量引用数查询.
//
// 与 CountActiveJobsUsingTemplate 的差异:
//   - 单条 SQL 批量返回 (GROUP BY prompt_template_id), 避免 N+1.
//   - **按 caller tenant 过滤**: 只统计本租户名下的 active cron (admin 列表展示"我能管的").
//   - tenant 模板: 只有本租户能创建引用, 计数与全局口径等价.
//   - platform 模板: 其他租户引用对本租户管理员不可见, 只数本租户的引用.
//   - active 口径与 CountActiveJobsUsingTemplate 一致: deleted_at IS NULL
//     (不再加 enabled / status='active' 的复杂过滤, 与删除校验语义对齐, 避免
//     列表显示 0 但删除失败的契约错位).
//
// 空 templateIDs → 返回空 map; 找不到引用的模板 id 在 map 中不出现 (caller 用 map[id]==0
// 兜底). 返回 map 永远 non-nil.
func (r *Repo) CountActiveJobsByTemplateIDs(ctx context.Context, tenantID int64, templateIDs []int64) (map[int64]int, error) {
	out := make(map[int64]int, len(templateIDs))
	if len(templateIDs) == 0 {
		return out, nil
	}
	rows, err := r.pool.Query(ctx,
		`SELECT prompt_template_id, COUNT(*)
		   FROM agent_cron_jobs
		  WHERE tenant_id = $1
		    AND deleted_at IS NULL
		    AND prompt_template_id = ANY($2::bigint[])
		  GROUP BY prompt_template_id`, tenantID, templateIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var n int
		if err := rows.Scan(&id, &n); err != nil {
			return nil, err
		}
		out[id] = n
	}
	return out, rows.Err()
}

// ListVisiblePromptTemplates · G3 / F08 §3.1.1 · client 端模板列表.
//
// 可见性规则 (与 resolvePromptTemplate / §9 R12 一致):
//   - scope='platform' AND status='active' AND is_deleted=false → 跨租户可见
//   - scope='tenant'   AND tenant_id=caller AND status='active' AND is_deleted=false → 本租户可见
//
// 返回值按 (scope_kind ASC, code ASC) 排序: platform 模板排在前, 同 scope 内按 code 稳定排序.
// limit <=0 / >limit 上限 200 时走默认 100.
func (r *Repo) ListVisiblePromptTemplates(ctx context.Context, tenantID int64, limit int) ([]domcron.PromptTemplate, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := r.pool.Query(ctx,
		`SELECT `+promptTplCols+`
		   FROM cron_prompt_templates
		  WHERE is_deleted=false
		    AND status='active'
		    AND (scope_kind='platform'
		         OR (scope_kind='tenant' AND tenant_id=$1))
		  ORDER BY scope_kind ASC, code ASC
		  LIMIT $2`, tenantID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domcron.PromptTemplate{}
	for rows.Next() {
		t, err := scanPromptTemplate(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *t)
	}
	return out, rows.Err()
}

// ListPromptTemplateVariables · R9 · 拉模板的变量定义, 按 order_index ASC.
func (r *Repo) ListPromptTemplateVariables(ctx context.Context, templateID int64) ([]domcron.PromptTemplateVariable, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT id, template_id, var_name, var_type, required, default_value, options,
		        COALESCE(display_name,''), order_index
		   FROM cron_prompt_template_variables
		  WHERE template_id=$1 AND is_deleted=false
		  ORDER BY order_index ASC, id ASC`, templateID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domcron.PromptTemplateVariable{}
	for rows.Next() {
		var v domcron.PromptTemplateVariable
		var defaultVal, opts []byte
		if err := rows.Scan(&v.ID, &v.TemplateID, &v.VarName, &v.VarType, &v.Required,
			&defaultVal, &opts, &v.DisplayName, &v.OrderIndex); err != nil {
			return nil, err
		}
		if len(defaultVal) > 0 && string(defaultVal) != "null" {
			_ = json.Unmarshal(defaultVal, &v.DefaultValue)
		}
		if len(opts) > 0 && string(opts) != "null" {
			_ = json.Unmarshal(opts, &v.Options)
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

// ---- helpers ----

func nullableString(s string) any {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return s
}

func itoa(n int) string {
	return strconv.Itoa(n)
}

// Apply availability before LIMIT: offline owners cannot monopolize the batch.
func localDesktopReadySQL(owner string) string {
	return `(NOT EXISTS(SELECT 1 FROM digital_employees e WHERE e.id=` + owner + `.agent_id AND e.execution_locus='local')
 OR EXISTS(SELECT 1 FROM (` + repolocal.OnlineDesktopPrincipalsSQL + `) online
 WHERE online.account_id=` + owner + `.account_id AND online.tenant_id=` + owner + `.tenant_id
 HAVING count(*)=1 AND bool_and(protocol_version>=2)))`
}

// RequeueUnstartedRun is only used before a trigger/message/task has been created.
func (r *Repo) RequeueUnstartedRun(ctx context.Context, id int64) error {
	_, err := r.pool.Exec(ctx, `UPDATE agent_cron_runs SET status='queued' WHERE id=$1 AND status='running' AND message_uuid IS NULL`, id)
	return err
}

// NewCommunity excludes local desktop work without referencing private device tables.
func NewCommunity(pool *pgxpool.Pool) *Repo { r := New(pool); r.community = true; return r }
func (r *Repo) desktopReadySQL(owner string) string {
	if r.community {
		return "EXISTS (SELECT 1 FROM digital_employees de WHERE de.id=" + owner + ".agent_id AND de.execution_locus <> 'local')"
	}
	return localDesktopReadySQL(owner)
}
