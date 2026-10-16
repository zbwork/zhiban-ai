// Package runtimeenv (postgres) — F02 v0.3 runtime_environments 合表 +
// tenant_runtime_enablements + runtime_instances (pending ensure) 数据访问。
//
// 旧底表 (runtime_registrations + runtime_hosting_configs) 已被
// migration 000060 删除并合并入 runtime_environments; scope + hosting_kind
// 二维区分 4 类环境 (platform clawmanager/k8s_native; tenant clawmanager/
// k8s_native/external_endpoint)。
package runtimeenv

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/runtimeenv"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/auditpg"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

// envCols 选 runtime_environments 的全字段; 全部 COALESCE 处理 NULL 字符串/整数。
// 顺序必须与 scanEnv 一一对应。
const envCols = `
id, uuid, created_at, created_by, updated_at, updated_by, is_deleted, deleted_at,
scope, tenant_id,
name, COALESCE(description,''), framework, hosting_kind,
status, enabled, open_to_tenants,
COALESCE(primary_endpoint,''), COALESCE(api_key_secret_ref,''), COALESCE(external_environment_id,''),
COALESCE(workload_api_base_url,''), COALESCE(workload_api_token_secret_ref,''),
COALESCE(k8s_api_server_url,''), COALESCE(k8s_token_secret_ref,''),
COALESCE(k8s_namespace,''), k8s_insecure_skip_verify,
COALESCE(image_repository,''), COALESCE(image_tag,''),
COALESCE(gateway_port,0), COALESCE(mount_path,''), COALESCE(storage_class,''),
COALESCE(default_cpu_cores,0), COALESCE(default_memory_gb,0), COALESCE(default_disk_gb,0),
workload_env,
COALESCE(llm_default_model,''), COALESCE(http_proxy,''), COALESCE(https_proxy,''), COALESCE(no_proxy,''),
last_probed_at, COALESCE(last_probe_status,''), COALESCE(last_probe_message,''),
COALESCE(last_probe_latency_ms,0),
COALESCE(data_egress,''), egress_audit_status, COALESCE(egress_audit_reason,''),
egress_auditor_id, egress_reviewed_at, egress_compliance_docs,
rate_limit, metadata, COALESCE(framework_config, '{}'::jsonb)
`

func scanEnv(row pgx.Row) (*dom.Env, error) {
	var x dom.Env
	var workloadEnv, complianceDocs, rateLimit, meta, fwCfgBytes []byte
	if err := row.Scan(
		&x.ID, &x.UUID, &x.CreatedAt, &x.CreatedBy, &x.UpdatedAt, &x.UpdatedBy, &x.IsDeleted, &x.DeletedAt,
		&x.Scope, &x.TenantID,
		&x.Name, &x.Description, &x.Framework, &x.HostingKind,
		&x.Status, &x.Enabled, &x.OpenToTenants,
		&x.PrimaryEndpoint, &x.APIKeySecretRef, &x.ExternalEnvironmentID,
		&x.WorkloadAPIBaseURL, &x.WorkloadAPITokenSecretRef,
		&x.K8sAPIServerURL, &x.K8sTokenSecretRef,
		&x.K8sNamespace, &x.K8sInsecureSkipVerify,
		&x.ImageRepository, &x.ImageTag,
		&x.GatewayPort, &x.MountPath, &x.StorageClass,
		&x.DefaultCPUCores, &x.DefaultMemoryGB, &x.DefaultDiskGB,
		&workloadEnv,
		&x.LLMDefaultModel, &x.HTTPProxy, &x.HTTPSProxy, &x.NoProxy,
		&x.LastProbedAt, &x.LastProbeStatus, &x.LastProbeMessage, &x.LastProbeLatencyMs,
		&x.DataEgress, &x.EgressAuditStatus, &x.EgressAuditReason,
		&x.EgressAuditorID, &x.EgressReviewedAt, &complianceDocs,
		&rateLimit, &meta, &fwCfgBytes,
	); err != nil {
		return nil, err
	}
	if len(workloadEnv) > 0 {
		_ = json.Unmarshal(workloadEnv, &x.WorkloadEnv)
	}
	if len(complianceDocs) > 0 {
		_ = json.Unmarshal(complianceDocs, &x.EgressComplianceDocs)
	}
	if len(rateLimit) > 0 {
		_ = json.Unmarshal(rateLimit, &x.RateLimit)
	}
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &x.Metadata)
	}
	if len(fwCfgBytes) > 0 {
		_ = json.Unmarshal(fwCfgBytes, &x.FrameworkConfig)
	}
	return &x, nil
}

func (r *Repo) GetByID(ctx context.Context, id int64) (*dom.Env, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+envCols+` FROM runtime_environments WHERE id=$1 AND is_deleted=false`, id)
	x, err := scanEnv(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

// NameByIDs 批量解析 runtime environment 的对外 uuid/name, 供客户端 DTO 组装避免 N+1 查询。
func (r *Repo) NameByIDs(ctx context.Context, ids []int64) (map[int64][2]string, error) {
	out := map[int64][2]string{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := r.pool.Query(ctx, `
SELECT id, uuid::text, name
FROM runtime_environments
WHERE id = ANY($1::bigint[]) AND is_deleted=false`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var uuid, name string
		if err := rows.Scan(&id, &uuid, &name); err != nil {
			return nil, err
		}
		out[id] = [2]string{uuid, name}
	}
	return out, rows.Err()
}

// DescribeByIDs 批量解析客户端 agent DTO 需要的环境展示信息与 framework。
// framework 仅在服务端判断能力边界，不直接作为客户端可编辑字段下发。
func (r *Repo) DescribeByIDs(ctx context.Context, ids []int64) (map[int64][3]string, error) {
	out := map[int64][3]string{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := r.pool.Query(ctx, `
SELECT id, uuid::text, name, framework
FROM runtime_environments
WHERE id = ANY($1::bigint[]) AND is_deleted=false`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var uuid, name, framework string
		if err := rows.Scan(&id, &uuid, &name, &framework); err != nil {
			return nil, err
		}
		out[id] = [3]string{uuid, name, framework}
	}
	return out, rows.Err()
}

func (r *Repo) GetByUUID(ctx context.Context, uuid string) (*dom.Env, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+envCols+` FROM runtime_environments WHERE uuid=$1 AND is_deleted=false`, uuid)
	x, err := scanEnv(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

// ListPlatform 列出 scope=platform 行。
//
// F02 v0.3: 不再有 `is_platform_default` 单一默认标记 (改租户级 enablement.is_default)。
// 排序按 id ASC。
func (r *Repo) ListPlatform(ctx context.Context, includeDisabled bool) ([]dom.Env, error) {
	q := `SELECT ` + envCols + ` FROM runtime_environments
	      WHERE scope='platform' AND is_deleted=false`
	if !includeDisabled {
		q += ` AND status='active'`
	}
	q += ` ORDER BY id ASC`
	return r.queryEnvs(ctx, q)
}

// ListTenantCustom 列出某租户的 scope=tenant 自定义环境 (active)。
func (r *Repo) ListTenantCustom(ctx context.Context, tenantID int64) ([]dom.Env, error) {
	q := `SELECT ` + envCols + ` FROM runtime_environments
	      WHERE scope='tenant' AND tenant_id=$1 AND is_deleted=false
	        AND status='active'
	      ORDER BY id DESC`
	return r.queryEnvs(ctx, q, tenantID)
}

// ListPersonal 列出某账号的 scope=personal 行 — v0.3 已移除 personal scope, 此方法
// 保留 stub 防 service 层调用方编译失败; 总是返回空切片, S4c 移除调用点后 S4d 删。
//
// Deprecated: F02 v0.3 移除 personal scope。
func (r *Repo) ListPersonal(ctx context.Context, accountID int64) ([]dom.Env, error) {
	return []dom.Env{}, nil
}

func (r *Repo) queryEnvs(ctx context.Context, q string, args ...any) ([]dom.Env, error) {
	rows, err := r.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.Env
	for rows.Next() {
		x, err := scanEnv(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *x)
	}
	return out, rows.Err()
}

// PlatformDefault — v0.3 取消"全平台单一默认"概念; 默认现在是租户级
// (tenant_runtime_enablements.is_default)。此方法保留 stub 返回首个
// 满足条件的 platform env, 让旧 caller 不崩, S4c/d 重写。
//
// Deprecated: F02 v0.3 改用 tenant_runtime_enablements.is_default。
func (r *Repo) PlatformDefault(ctx context.Context) (*dom.Env, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+envCols+` FROM runtime_environments
	    WHERE scope='platform' AND enabled=true AND open_to_tenants=true
	      AND status='active'
	      AND is_deleted=false
	    ORDER BY id ASC LIMIT 1`)
	x, err := scanEnv(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

// SetPlatformDefault — v0.3 行为变更: 不再写 is_platform_default 列 (已删);
// 改为把目标 env metadata.is_platform_default 标 true, 同 tx 把同 scope 其他行清掉。
// 真正的默认语义已转移到 tenant_runtime_enablements.is_default; 这个 method 仅供
// 老 admin UI 编辑期保留, S4c/d 替换 caller 后整体删除。
//
// Deprecated: F02 v0.3 改用 tenant_runtime_enablements.is_default。
func (r *Repo) SetPlatformDefault(ctx context.Context, id int64) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var scope, status string
	if err := tx.QueryRow(ctx, `SELECT scope, status
	    FROM runtime_environments WHERE id=$1 AND is_deleted=false`, id).Scan(&scope, &status); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		return err
	}
	if scope != "platform" {
		return apperr.ErrInvalidParams.Withf("not a platform-scope env")
	}
	if status != "active" {
		return apperr.ErrConflict.Withf("env status=%s, must be active", status)
	}
	// 清掉同 scope 旧默认标记。
	if _, err := tx.Exec(ctx, `UPDATE runtime_environments
	    SET metadata = metadata - 'is_platform_default'
	    WHERE scope='platform' AND id<>$1 AND is_deleted=false
	      AND metadata ? 'is_platform_default'`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE runtime_environments
	    SET metadata = jsonb_set(COALESCE(metadata,'{}'::jsonb), '{is_platform_default}', 'true'::jsonb)
	    WHERE id=$1`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify('config_change', $1)`, fmt.Sprintf("runtime_environments:%d", id)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// CountEnablementsByRuntime 计算引用某 runtime 的活跃 tenant_runtime_enablements 数。
func (r *Repo) CountEnablementsByRuntime(ctx context.Context, runtimeID int64) (int64, error) {
	var n int64
	err := r.pool.QueryRow(ctx, `SELECT count(*) FROM tenant_runtime_enablements
	    WHERE runtime_environment_id=$1 AND is_deleted=false`, runtimeID).Scan(&n)
	return n, err
}

// CountAgentsByRuntime 计算引用某 runtime 的 digital_employees 数 (跨租户)。
func (r *Repo) CountAgentsByRuntime(ctx context.Context, runtimeID int64) (int64, error) {
	var n int64
	err := r.pool.QueryRow(ctx, `SELECT count(*) FROM digital_employees
	    WHERE runtime_environment_id=$1 AND is_deleted=false`, runtimeID).Scan(&n)
	return n, err
}

// CountInstancesByRuntime 计算引用某 runtime 的活跃 runtime_instances。
func (r *Repo) CountInstancesByRuntime(ctx context.Context, runtimeID int64) (int64, error) {
	var n int64
	err := r.pool.QueryRow(ctx, `SELECT count(*) FROM runtime_instances
	    WHERE runtime_environment_id=$1 AND is_deleted=false AND status NOT IN ('stopped','failed')`, runtimeID).Scan(&n)
	return n, err
}

// CountAgentsByRuntimeAndTenant 计算某租户内引用某 runtime 的 digital_employees 数。
func (r *Repo) CountAgentsByRuntimeAndTenant(ctx context.Context, runtimeID, tenantID int64) (int64, []string, error) {
	rows, err := r.pool.Query(ctx, `SELECT uuid FROM digital_employees
	    WHERE runtime_environment_id=$1 AND tenant_id=$2 AND is_deleted=false`, runtimeID, tenantID)
	if err != nil {
		return 0, nil, err
	}
	defer rows.Close()
	var uuids []string
	for rows.Next() {
		var u string
		if err := rows.Scan(&u); err != nil {
			return 0, nil, err
		}
		uuids = append(uuids, u)
	}
	return int64(len(uuids)), uuids, rows.Err()
}

// SoftDelete 软删 runtime_environments 行 + pg_notify。
func (r *Repo) SoftDelete(ctx context.Context, id int64) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `UPDATE runtime_environments
	    SET is_deleted=true, deleted_at=now()
	    WHERE id=$1 AND is_deleted=false`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify('config_change', $1)`, fmt.Sprintf("runtime_environments:%d", id)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// ===== Custom (tenant) create / patch =====

// CreateCustom 在事务内插入 runtime_environments 行 + 同 tx pg_notify。
//
// 支持所有 hosting_kind (ADR-0022 v0.4): external_endpoint / clawmanager / k8s_native;
// scope='tenant' 时三种都能用。HostingKind 缺省回落到 external_endpoint 兼容旧调用方。
// primary_endpoint 由 service 层从入参推 (external_endpoint 直接填; clawmanager/k8s_native
// 实例 ensure 后回填)。
func (r *Repo) CreateCustom(ctx context.Context, env *dom.Env) (*dom.Env, error) {
	hostingKind := env.HostingKind
	if hostingKind == "" {
		hostingKind = "external_endpoint"
	}
	metaJSON, _ := json.Marshal(emptyMap(env.Metadata))
	workloadEnvJSON, _ := json.Marshal(emptyMap(env.WorkloadEnv))
	rateLimitJSON, _ := json.Marshal(emptyMap(env.RateLimit))
	complianceJSON, _ := json.Marshal(emptyMap(env.EgressComplianceDocs))
	fwCfgJSON, _ := json.Marshal(emptyMap(env.FrameworkConfig))
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	row := tx.QueryRow(ctx, `
INSERT INTO runtime_environments
    (scope, tenant_id, name, description, framework, hosting_kind,
     status, enabled, open_to_tenants,
     primary_endpoint, api_key_secret_ref, external_environment_id,
     workload_api_base_url, workload_api_token_secret_ref,
     k8s_api_server_url, k8s_token_secret_ref, k8s_namespace, k8s_insecure_skip_verify,
     image_repository, image_tag, gateway_port, mount_path, storage_class,
     default_cpu_cores, default_memory_gb, default_disk_gb, workload_env,
     llm_default_model, http_proxy, https_proxy, no_proxy,
     data_egress, egress_audit_status, egress_compliance_docs,
     rate_limit, metadata, framework_config,
     created_by, updated_by)
VALUES
    ($1, $2, $3, NULLIF($4,''), $5, $6,
     'active', true, false,
     NULLIF($7,''), NULLIF($8,''), NULLIF($9,''),
     NULLIF($10,''), NULLIF($11,''),
     NULLIF($12,''), NULLIF($13,''), COALESCE(NULLIF($14,''),'aigc'), $15,
     NULLIF($16,''), NULLIF($17,''), COALESCE(NULLIF($18,0),18789), COALESCE(NULLIF($19,''),'/workspace'), NULLIF($20,''),
     COALESCE(NULLIF($21,0),2), COALESCE(NULLIF($22,0),4), COALESCE(NULLIF($23,0),10), $24::jsonb,
     NULLIF($25,''), NULLIF($26,''), NULLIF($27,''), NULLIF($28,''),
     COALESCE(NULLIF($29,''),'platform-only'), 'approved', $30::jsonb,
     $31::jsonb, $32::jsonb, COALESCE($33::jsonb, '{}'::jsonb),
     $34, $34)
RETURNING `+envCols,
		env.Scope, env.TenantID, env.Name, env.Description, env.Framework, hostingKind,
		env.PrimaryEndpoint, env.APIKeySecretRef, env.ExternalEnvironmentID,
		env.WorkloadAPIBaseURL, env.WorkloadAPITokenSecretRef,
		env.K8sAPIServerURL, env.K8sTokenSecretRef, env.K8sNamespace, env.K8sInsecureSkipVerify,
		env.ImageRepository, env.ImageTag, env.GatewayPort, env.MountPath, env.StorageClass,
		env.DefaultCPUCores, env.DefaultMemoryGB, env.DefaultDiskGB, string(workloadEnvJSON),
		env.LLMDefaultModel, env.HTTPProxy, env.HTTPSProxy, env.NoProxy,
		env.DataEgress, string(complianceJSON),
		string(rateLimitJSON), string(metaJSON), string(fwCfgJSON),
		auditpg.Actor(ctx),
	)
	got, err := scanEnv(row)
	if err != nil {
		if pgIsUniqueViolation(err) {
			return nil, apperr.ErrConflict.Withf("env name %q already exists in this scope", env.Name)
		}
		return nil, err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify('config_change', $1)`, fmt.Sprintf("runtime_environments:%d", got.ID)); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return got, nil
}

// PatchCustom 增量更新 scope=tenant 行。fields snake_case key 控制允许列。
func (r *Repo) PatchCustom(ctx context.Context, id int64, fields map[string]any) (*dom.Env, error) {
	if len(fields) == 0 {
		return r.GetByID(ctx, id)
	}
	colMap := map[string]struct {
		col   string
		jsonb bool
	}{
		"name":                          {"name", false},
		"description":                   {"description", false},
		"primary_endpoint":              {"primary_endpoint", false},
		"api_key_secret_ref":            {"api_key_secret_ref", false},
		"external_environment_id":       {"external_environment_id", false},
		"workload_api_base_url":         {"workload_api_base_url", false},
		"workload_api_token_secret_ref": {"workload_api_token_secret_ref", false},
		"k8s_api_server_url":            {"k8s_api_server_url", false},
		"k8s_token_secret_ref":          {"k8s_token_secret_ref", false},
		"k8s_namespace":                 {"k8s_namespace", false},
		"image_repository":              {"image_repository", false},
		"image_tag":                     {"image_tag", false},
		"gateway_port":                  {"gateway_port", false},
		"mount_path":                    {"mount_path", false},
		"storage_class":                 {"storage_class", false},
		"default_cpu_cores":             {"default_cpu_cores", false},
		"default_memory_gb":             {"default_memory_gb", false},
		"default_disk_gb":               {"default_disk_gb", false},
		"workload_env":                  {"workload_env", true},
		"llm_default_model":             {"llm_default_model", false},
		"http_proxy":                    {"http_proxy", false},
		"https_proxy":                   {"https_proxy", false},
		"no_proxy":                      {"no_proxy", false},
		"data_egress":                   {"data_egress", false},
		"rate_limit":                    {"rate_limit", true},
		"metadata":                      {"metadata", true},
		"framework_config":              {"framework_config", true},
	}
	sets := []string{}
	args := []any{}
	idx := 1
	for k, v := range fields {
		c, ok := colMap[k]
		if !ok {
			continue
		}
		if c.jsonb {
			b, _ := json.Marshal(v)
			args = append(args, string(b))
			sets = append(sets, c.col+" = $"+itoa(idx)+"::jsonb")
		} else {
			args = append(args, v)
			sets = append(sets, c.col+" = $"+itoa(idx))
		}
		idx++
	}
	if len(sets) == 0 {
		return r.GetByID(ctx, id)
	}
	args = append(args, id)
	// ADR-0011: PATCH 路径自动写 updated_by。
	args = append(args, auditpg.Actor(ctx))
	q := `UPDATE runtime_environments SET ` + joinSets(sets) +
		`, updated_by = $` + itoa(idx+1) +
		` WHERE id = $` + itoa(idx) + ` AND is_deleted=false AND scope='tenant'
	      RETURNING ` + envCols
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	row := tx.QueryRow(ctx, q, args...)
	got, err := scanEnv(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify('config_change', $1)`, fmt.Sprintf("runtime_environments:%d", got.ID)); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return got, nil
}

// MarkProbeOK records the successful dry-run probe that guarded a tenant custom
// create/patch request, so tenant admins can see the connectivity state in list.
func (r *Repo) MarkProbeOK(ctx context.Context, id int64, message string) (*dom.Env, error) {
	msg := strings.TrimSpace(message)
	if msg == "" {
		msg = "runtime probe passed"
	}
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	row := tx.QueryRow(ctx, `
UPDATE runtime_environments
SET last_probed_at=now(),
    last_probe_status='ok',
    last_probe_message=NULLIF($2,''),
    last_probe_latency_ms=0,
    updated_by=$3
WHERE id=$1 AND is_deleted=false
RETURNING `+envCols, id, msg, auditpg.Actor(ctx))
	got, err := scanEnv(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify('config_change', $1)`, fmt.Sprintf("runtime_environments:%d", got.ID)); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return got, nil
}

// ===== Enablements =====

// EnablementList 三段视图: platform_enabled / platform_available / tenant_custom。
//
// v0.3: hosting 字段已合入 runtime_environments, 不再 JOIN runtime_hosting_configs。
// platform 段过滤条件: enabled=true AND open_to_tenants=true (列直接在 runtime_environments)。
func (r *Repo) EnablementList(ctx context.Context, tenantID int64) (*dom.TenantListResult, error) {
	// platform_enabled: 在 tre 且仍 active / enabled / open_to_tenants
	q := `SELECT ` + envColsPrefixed("re") + `,
	             COALESCE(tre.is_default, false) AS is_default,
	             tre.uuid::text AS enablement_uuid
	      FROM runtime_environments re
	      JOIN tenant_runtime_enablements tre
	        ON tre.runtime_environment_id = re.id AND tre.tenant_id=$1 AND tre.is_deleted=false
	      WHERE re.scope='platform' AND re.is_deleted=false
	        AND re.status='active'
	        AND re.enabled=true AND re.open_to_tenants=true
	      ORDER BY tre.is_default DESC, re.id ASC`
	enabled, err := r.queryEnvsWithEnablement(ctx, q, tenantID)
	if err != nil {
		return nil, err
	}
	// platform_available: 不在 tre
	q2 := `SELECT ` + envColsPrefixed("re") + `
	      FROM runtime_environments re
	      WHERE re.scope='platform' AND re.is_deleted=false
	        AND re.status='active'
	        AND re.enabled=true AND re.open_to_tenants=true
	        AND NOT EXISTS (
	          SELECT 1 FROM tenant_runtime_enablements t
	          WHERE t.runtime_environment_id=re.id AND t.tenant_id=$1 AND t.is_deleted=false)
	      ORDER BY re.id ASC`
	available, err := r.queryEnvs(ctx, q2, tenantID)
	if err != nil {
		return nil, err
	}
	custom, err := r.ListTenantCustom(ctx, tenantID)
	if err != nil {
		return nil, err
	}
	if enabled == nil {
		enabled = []dom.Env{}
	}
	if available == nil {
		available = []dom.Env{}
	}
	if custom == nil {
		custom = []dom.Env{}
	}
	return &dom.TenantListResult{
		PlatformEnabled:   enabled,
		PlatformAvailable: available,
		TenantCustom:      custom,
	}, nil
}

// envColsPrefixed 给 envCols 加表别名 (re.id, re.uuid, ...) 用在 JOIN 查询。
// 跟 envCols 用 SELECT * 隐式别名不同, JOIN 必须 qualified 防同名冲突。
//
// 注: 原先用 strings.Split(envCols, ",") + COALESCE 拆解的算法会把 COALESCE(x,”)
// 内部的逗号当成列分隔, 产生 `re.”)` 类语法错误。现改为返回明确的 alias-prefixed 字符串,
// 跟 envCols 内容一一对应; 改 envCols 也要改这里。
func envColsPrefixed(alias string) string {
	a := alias + "."
	return a + "id, " + a + "uuid, " + a + "created_at, " + a + "created_by, " + a + "updated_at, " + a + "updated_by, " + a + "is_deleted, " + a + "deleted_at, " +
		a + "scope, " + a + "tenant_id, " +
		a + "name, COALESCE(" + a + "description,''), " + a + "framework, " + a + "hosting_kind, " +
		a + "status, " + a + "enabled, " + a + "open_to_tenants, " +
		"COALESCE(" + a + "primary_endpoint,''), COALESCE(" + a + "api_key_secret_ref,''), COALESCE(" + a + "external_environment_id,''), " +
		"COALESCE(" + a + "workload_api_base_url,''), COALESCE(" + a + "workload_api_token_secret_ref,''), " +
		"COALESCE(" + a + "k8s_api_server_url,''), COALESCE(" + a + "k8s_token_secret_ref,''), " +
		"COALESCE(" + a + "k8s_namespace,''), " + a + "k8s_insecure_skip_verify, " +
		"COALESCE(" + a + "image_repository,''), COALESCE(" + a + "image_tag,''), " +
		"COALESCE(" + a + "gateway_port,0), COALESCE(" + a + "mount_path,''), COALESCE(" + a + "storage_class,''), " +
		"COALESCE(" + a + "default_cpu_cores,0), COALESCE(" + a + "default_memory_gb,0), COALESCE(" + a + "default_disk_gb,0), " +
		a + "workload_env, " +
		"COALESCE(" + a + "llm_default_model,''), COALESCE(" + a + "http_proxy,''), " +
		"COALESCE(" + a + "https_proxy,''), COALESCE(" + a + "no_proxy,''), " +
		a + "last_probed_at, COALESCE(" + a + "last_probe_status,''), COALESCE(" + a + "last_probe_message,''), " +
		"COALESCE(" + a + "last_probe_latency_ms,0), " +
		"COALESCE(" + a + "data_egress,''), " + a + "egress_audit_status, COALESCE(" + a + "egress_audit_reason,''), " +
		a + "egress_auditor_id, " + a + "egress_reviewed_at, " + a + "egress_compliance_docs, " +
		a + "rate_limit, " + a + "metadata, COALESCE(" + a + "framework_config, '{}'::jsonb)"
}

// qualifyCol legacy helper — 被新的明确 envColsPrefixed 替换, 保留以防外部调用 (无人调)。
func qualifyCol(expr, alias string) string {
	// 找最左裸列名 (字母/下划线开头)。
	low := strings.ToLower(expr)
	if strings.HasPrefix(low, "coalesce(") {
		// COALESCE(col, default) 形式
		open := strings.Index(expr, "(")
		comma := strings.Index(expr[open:], ",")
		if comma > 0 {
			colExpr := expr[open+1 : open+comma]
			return "COALESCE(" + alias + "." + strings.TrimSpace(colExpr) + expr[open+comma:]
		}
	}
	// 直接列名
	return alias + "." + expr
}

// queryEnvsWithEnablement 在 envCols 后追加 is_default + enablement_uuid 两列。
func (r *Repo) queryEnvsWithEnablement(ctx context.Context, q string, args ...any) ([]dom.Env, error) {
	rows, err := r.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.Env
	for rows.Next() {
		var x dom.Env
		var workloadEnv, complianceDocs, rateLimit, meta, fwCfgBytes []byte
		if err := rows.Scan(
			&x.ID, &x.UUID, &x.CreatedAt, &x.CreatedBy, &x.UpdatedAt, &x.UpdatedBy, &x.IsDeleted, &x.DeletedAt,
			&x.Scope, &x.TenantID,
			&x.Name, &x.Description, &x.Framework, &x.HostingKind,
			&x.Status, &x.Enabled, &x.OpenToTenants,
			&x.PrimaryEndpoint, &x.APIKeySecretRef, &x.ExternalEnvironmentID,
			&x.WorkloadAPIBaseURL, &x.WorkloadAPITokenSecretRef,
			&x.K8sAPIServerURL, &x.K8sTokenSecretRef,
			&x.K8sNamespace, &x.K8sInsecureSkipVerify,
			&x.ImageRepository, &x.ImageTag,
			&x.GatewayPort, &x.MountPath, &x.StorageClass,
			&x.DefaultCPUCores, &x.DefaultMemoryGB, &x.DefaultDiskGB,
			&workloadEnv,
			&x.LLMDefaultModel, &x.HTTPProxy, &x.HTTPSProxy, &x.NoProxy,
			&x.LastProbedAt, &x.LastProbeStatus, &x.LastProbeMessage, &x.LastProbeLatencyMs,
			&x.DataEgress, &x.EgressAuditStatus, &x.EgressAuditReason,
			&x.EgressAuditorID, &x.EgressReviewedAt, &complianceDocs,
			&rateLimit, &meta, &fwCfgBytes,
			&x.IsDefaultForCaller, &x.EnablementUUID,
		); err != nil {
			return nil, err
		}
		if len(workloadEnv) > 0 {
			_ = json.Unmarshal(workloadEnv, &x.WorkloadEnv)
		}
		if len(complianceDocs) > 0 {
			_ = json.Unmarshal(complianceDocs, &x.EgressComplianceDocs)
		}
		if len(rateLimit) > 0 {
			_ = json.Unmarshal(rateLimit, &x.RateLimit)
		}
		if len(meta) > 0 {
			_ = json.Unmarshal(meta, &x.Metadata)
		}
		if len(fwCfgBytes) > 0 {
			_ = json.Unmarshal(fwCfgBytes, &x.FrameworkConfig)
		}
		out = append(out, x)
	}
	return out, rows.Err()
}

// CountActiveEnablements 给某租户的有效启用数量。
func (r *Repo) CountActiveEnablements(ctx context.Context, tenantID int64) (int64, error) {
	var n int64
	err := r.pool.QueryRow(ctx, `SELECT count(*) FROM tenant_runtime_enablements
	    WHERE tenant_id=$1 AND is_deleted=false`, tenantID).Scan(&n)
	return n, err
}

// Enable 在 tenant_runtime_enablements 插入一行; 软删行复活。同 tx pg_notify。
func (r *Repo) Enable(ctx context.Context, tenantID, runtimeEnvID int64, enabledBy int64, makeDefault bool) (*dom.Enablement, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	// 校 runtime: scope=platform AND active+enabled+open_to_tenants;
	// 或 scope=tenant AND tenant_id=本租户。
	var scope, status string
	var ownerT *int64
	var enabled, openToTenants bool
	if err := tx.QueryRow(ctx, `SELECT scope, status, tenant_id, enabled, open_to_tenants
	    FROM runtime_environments WHERE id=$1 AND is_deleted=false`, runtimeEnvID).Scan(&scope, &status, &ownerT, &enabled, &openToTenants); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	if scope == "tenant" && (ownerT == nil || *ownerT != tenantID) {
		return nil, apperr.ErrForbidden.Withf("tenant-scope env owned by another tenant")
	}
	if scope == "platform" && (!enabled || !openToTenants) {
		return nil, apperr.ErrConflict.Withf("platform env enabled=%v open_to_tenants=%v", enabled, openToTenants)
	}
	if status != "active" {
		return nil, apperr.ErrConflict.Withf("env not active (status=%s)", status)
	}
	// 已存在活跃行 → 返回 (幂等)
	en, err := r.fetchActiveEnablement(ctx, tx, tenantID, runtimeEnvID)
	if err == nil {
		return en, tx.Commit(ctx)
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	// 复活软删行 (避免 partial unique 冲突)
	if _, err := tx.Exec(ctx, `UPDATE tenant_runtime_enablements
	    SET is_deleted=false, deleted_at=NULL, created_at=now(), created_by=$3, is_default=$4
	    WHERE tenant_id=$1 AND runtime_environment_id=$2 AND is_deleted=true`,
		tenantID, runtimeEnvID, enabledBy, makeDefault); err != nil {
		return nil, err
	}
	// 新增 — ON CONFLICT 走 partial unique (tenant_id, runtime_environment_id) WHERE is_deleted=false。
	if _, err := tx.Exec(ctx, `
INSERT INTO tenant_runtime_enablements (tenant_id, runtime_environment_id, is_default, created_by)
VALUES ($1, $2, $3, $4)
ON CONFLICT (tenant_id, runtime_environment_id) WHERE is_deleted = false DO NOTHING`,
		tenantID, runtimeEnvID, makeDefault, enabledBy); err != nil {
		return nil, err
	}
	en, err = r.fetchActiveEnablement(ctx, tx, tenantID, runtimeEnvID)
	if err != nil {
		return nil, err
	}
	if makeDefault {
		if _, err := tx.Exec(ctx, `UPDATE tenant_runtime_enablements
		    SET is_default=false WHERE tenant_id=$1 AND id<>$2 AND is_deleted=false`, tenantID, en.ID); err != nil {
			return nil, err
		}
		en.IsDefault = true
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify('config_change', $1)`, fmt.Sprintf("tenant_runtime_enablements:%d", tenantID)); err != nil {
		return nil, err
	}
	return en, tx.Commit(ctx)
}

func (r *Repo) fetchActiveEnablement(ctx context.Context, tx pgx.Tx, tenantID, runtimeEnvID int64) (*dom.Enablement, error) {
	var en dom.Enablement
	row := tx.QueryRow(ctx, `SELECT id, uuid, created_at, created_by, updated_at, updated_by,
	         is_deleted, deleted_at, tenant_id, runtime_environment_id, is_default
	    FROM tenant_runtime_enablements
	    WHERE tenant_id=$1 AND runtime_environment_id=$2 AND is_deleted=false`, tenantID, runtimeEnvID)
	if err := row.Scan(&en.ID, &en.UUID, &en.CreatedAt, &en.CreatedBy, &en.UpdatedAt, &en.UpdatedBy,
		&en.IsDeleted, &en.DeletedAt, &en.TenantID, &en.RuntimeEnvironmentID, &en.IsDefault); err != nil {
		return nil, err
	}
	return &en, nil
}

// SetDefault 单 tx 切换默认环境; 旧默认 = false。
func (r *Repo) SetDefault(ctx context.Context, tenantID, enablementID int64) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var owner int64
	if err := tx.QueryRow(ctx, `SELECT tenant_id FROM tenant_runtime_enablements
	    WHERE id=$1 AND is_deleted=false`, enablementID).Scan(&owner); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		return err
	}
	if owner != tenantID {
		return apperr.ErrForbidden.Withf("enablement not owned by tenant")
	}
	if _, err := tx.Exec(ctx, `UPDATE tenant_runtime_enablements
	    SET is_default=false WHERE tenant_id=$1 AND id<>$2 AND is_deleted=false`, tenantID, enablementID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE tenant_runtime_enablements
	    SET is_default=true WHERE id=$1`, enablementID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify('config_change', $1)`, fmt.Sprintf("tenant_runtime_enablements:%d", tenantID)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Disable 软删 enablement; 同 tx pg_notify。
func (r *Repo) Disable(ctx context.Context, tenantID, enablementID int64) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var owner int64
	if err := tx.QueryRow(ctx, `SELECT tenant_id FROM tenant_runtime_enablements
	    WHERE id=$1 AND is_deleted=false`, enablementID).Scan(&owner); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		return err
	}
	if owner != tenantID {
		return apperr.ErrForbidden.Withf("enablement not owned by tenant")
	}
	if _, err := tx.Exec(ctx, `UPDATE tenant_runtime_enablements
	    SET is_deleted=true, deleted_at=now(), is_default=false WHERE id=$1`, enablementID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify('config_change', $1)`, fmt.Sprintf("tenant_runtime_enablements:%d", tenantID)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// GetEnablementByUUID 通过 uuid 查 enablement。
func (r *Repo) GetEnablementByUUID(ctx context.Context, uuid string) (*dom.Enablement, error) {
	var en dom.Enablement
	row := r.pool.QueryRow(ctx, `SELECT id, uuid, created_at, created_by, updated_at, updated_by,
	         is_deleted, deleted_at, tenant_id, runtime_environment_id, is_default
	    FROM tenant_runtime_enablements
	    WHERE uuid=$1 AND is_deleted=false`, uuid)
	if err := row.Scan(&en.ID, &en.UUID, &en.CreatedAt, &en.CreatedBy, &en.UpdatedAt, &en.UpdatedBy,
		&en.IsDeleted, &en.DeletedAt, &en.TenantID, &en.RuntimeEnvironmentID, &en.IsDefault); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return &en, nil
}

// ProvisionEnableDefault 给新租户开通时同 tx 初始化租户可用 Agent 环境清单。
//
// v0.3: hosting_kind / enabled / open_to_tenants 都在 runtime_environments, 不再 JOIN hosting_configs。
// 默认环境 = 第一行: 知办通用运行时 (framework=dsh) 优先, 其次按 id。2026-09-07 OpenClaw 环境退役 (status=disabled)
// 后, 纯按 id 会把 agent-example ZAP 示例环境当成新租户默认 (ADR-0035: dsh 是通用数字员工默认运行时)。
func (r *Repo) ProvisionEnableDefault(ctx context.Context, tx pgx.Tx, tenantID int64, byAccountID int64) error {
	rows, err := tx.Query(ctx, `
	    SELECT id FROM runtime_environments
	     WHERE scope='platform'
	       AND status='active'
	       AND is_deleted=false
	       AND enabled=true
	       AND open_to_tenants=true
	     ORDER BY (framework = 'dsh') DESC, id ASC`)
	if err != nil {
		return err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if len(ids) == 0 {
		return nil
	}
	for i, id := range ids {
		makeDefault := i == 0
		if _, err := tx.Exec(ctx, `INSERT INTO tenant_runtime_enablements
		    (tenant_id, runtime_environment_id, is_default, created_by)
		    VALUES ($1, $2, $3, $4)
		    ON CONFLICT (tenant_id, runtime_environment_id) WHERE is_deleted=false DO NOTHING`,
			tenantID, id, makeDefault, byAccountID); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify('config_change', $1)`,
		fmt.Sprintf("tenant_runtime_enablements:%d:provision", tenantID)); err != nil {
		return err
	}
	return nil
}

// ===== Runtime Instances (pending lifecycle minimal) =====

// EnsurePendingInstance 幂等地为 (tenant, account, runtime) 写一行 runtime_instances 预留。
// 已存在则返回现有行。
//
// v0.3: account_id → created_by; runtime_id → runtime_environment_id。
//
// agentUUID 为 nil 时是绝大多数场景——一个 (tenant,account,runtime) 共享一
// 个 pod（uq_runtime_inst_shared）；非 nil 时是 ADR-0037 BYOK 场景——这个
// 数字员工独占一个专属 pod（uq_runtime_inst_byok）。用
// `IS NOT DISTINCT FROM` 而不是 `=` 消歧，因为 SQL 的 `NULL = NULL` 恒为
// NULL（不匹配），必须用 NULL-safe 比较才能让"查 shared 行"和"查某个 BYOK
// agent 的专属行"互不串。
func (r *Repo) EnsurePendingInstance(ctx context.Context, tenantID, accountID, runtimeID int64, agentUUID *string) (string, string, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback(ctx)
	var (
		uuid   string
		status string
	)
	row := tx.QueryRow(ctx, `SELECT uuid, status FROM runtime_instances
	    WHERE tenant_id=$1 AND created_by=$2 AND runtime_environment_id=$3
	      AND agent_uuid IS NOT DISTINCT FROM $4 AND is_deleted=false`,
		tenantID, accountID, runtimeID, agentUUID)
	if err := row.Scan(&uuid, &status); err == nil {
		return uuid, status, tx.Commit(ctx)
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return "", "", err
	}
	if err := tx.QueryRow(ctx, `INSERT INTO runtime_instances
	    (tenant_id, created_by, runtime_environment_id, agent_uuid, status, metadata)
	    VALUES ($1, $2, $3, $4, 'pending', '{}'::jsonb)
	    RETURNING uuid, status`, tenantID, accountID, runtimeID, agentUUID).Scan(&uuid, &status); err != nil {
		return "", "", err
	}
	return uuid, status, tx.Commit(ctx)
}

// ===== helpers =====

func emptyMap(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

func joinSets(s []string) string { return strings.Join(s, ", ") }

func pgIsUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "unique constraint") || strings.Contains(s, "duplicate key")
}

// FindByExternalEnvironmentID 按 external_environment_id 找运行环境 (平台自营 dsh 运行时自动登记用的幂等标记;
// 仅透传字段, 不参与鉴权)。未找到 → (nil, nil)。多行时取最早创建的。
func (r *Repo) FindByExternalEnvironmentID(ctx context.Context, externalID string) (*dom.Env, error) {
	externalID = strings.TrimSpace(externalID)
	if externalID == "" {
		return nil, nil
	}
	envs, err := r.queryEnvs(ctx, `SELECT `+envCols+` FROM runtime_environments
		WHERE external_environment_id = $1 AND is_deleted = false ORDER BY id ASC LIMIT 1`, externalID)
	if err != nil {
		return nil, err
	}
	if len(envs) == 0 {
		return nil, nil
	}
	return &envs[0], nil
}
