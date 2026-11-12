// Package alert 是 F25 alerts / alert_rule_state 的 Postgres 仓储。
//
// 关键约束：
//   - UpsertFiring / AutoResolve / ResolveManual 内部把告警行变更与 notify.alert.* outbox 写入放在同一事务，
//     保证「告警可见 ⇔ 通知已入队」原子（边界文档 §6 通道；webhook 分发消费 notify.alert.%）。
//   - 租户侧一切读写带 tenantOnly 谓词（scope_kind='tenant' AND tenant_id=$X），
//     未命中一律 alert.not_found，不泄漏他租户告警存在性。
package alert

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/alert"
	domevent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	evtrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
)

// Repo 实现 domain/alert.Store。
type Repo struct {
	pool *pgxpool.Pool
	pub  domevent.Publisher
}

// New 构造；pub 用于同事务发 notify.alert.* outbox 事件。
func New(pool *pgxpool.Pool, pub domevent.Publisher) *Repo {
	return &Repo{pool: pool, pub: pub}
}

const alertCols = `id, uuid, scope_kind, tenant_id, source_kind, alert_type, severity, status, fingerprint,
    title, summary, resource_kind, resource_uuid, first_triggered_at, last_triggered_at, occurrence_count,
    acknowledged_by, acknowledged_at, resolved_at, resolved_by, context, created_at, updated_at`

func scanAlert(row pgx.Row) (*dom.Alert, error) {
	var a dom.Alert
	var ctxBytes []byte
	if err := row.Scan(&a.ID, &a.UUID, &a.ScopeKind, &a.TenantID, &a.SourceKind, &a.AlertType, &a.Severity,
		&a.Status, &a.Fingerprint, &a.Title, &a.Summary, &a.ResourceKind, &a.ResourceUUID,
		&a.FirstTriggeredAt, &a.LastTriggeredAt, &a.OccurrenceCount,
		&a.AcknowledgedBy, &a.AcknowledgedAt, &a.ResolvedAt, &a.ResolvedBy, &ctxBytes, &a.CreatedAt, &a.UpdatedAt); err != nil {
		return nil, err
	}
	if len(ctxBytes) > 0 {
		_ = json.Unmarshal(ctxBytes, &a.Context)
	}
	if a.Context == nil {
		a.Context = map[string]any{}
	}
	return &a, nil
}

// List 分页列表；平台侧 JOIN tenants 带租户名。
func (r *Repo) List(ctx context.Context, f dom.ListFilter) ([]dom.Alert, int64, error) {
	if f.Limit <= 0 || f.Limit > 200 {
		f.Limit = 20
	}
	if f.Offset < 0 {
		f.Offset = 0
	}
	where := `WHERE 1=1`
	args := []any{}
	add := func(cond string, v any) {
		args = append(args, v)
		where += ` AND ` + cond + `$` + strconv.Itoa(len(args))
	}
	if f.TenantOnly != nil {
		add(`a.scope_kind='tenant' AND a.tenant_id=`, *f.TenantOnly)
	} else {
		if f.TenantID != nil {
			add(`a.tenant_id=`, *f.TenantID)
		}
		// 平台侧默认排除租户经营类告警（行动方是租户；F25 §3 拍板口径）
		if !f.IncludeTenantOps && f.AlertType == "" {
			args = append(args, dom.TenantOpsAlertTypes)
			where += ` AND NOT (a.alert_type = ANY($` + strconv.Itoa(len(args)) + `))`
		}
	}
	if f.Status != "" {
		add(`a.status=`, f.Status)
	}
	if f.Severity != "" {
		add(`a.severity=`, f.Severity)
	}
	if f.SourceKind != "" {
		add(`a.source_kind=`, f.SourceKind)
	}
	if f.AlertType != "" {
		add(`a.alert_type=`, f.AlertType)
	}
	if f.From != nil {
		add(`a.last_triggered_at>=`, *f.From)
	}
	if f.To != nil {
		add(`a.last_triggered_at<=`, *f.To)
	}
	args = append(args, f.Limit, f.Offset)
	rows, err := r.pool.Query(ctx, `
SELECT `+prefixCols("a")+`, COALESCE(t.name,''), COUNT(*) OVER()
  FROM alerts a
  LEFT JOIN tenants t ON t.id = a.tenant_id
  `+where+`
 ORDER BY (a.status='firing') DESC, CASE a.severity WHEN 'critical' THEN 0 ELSE 1 END, a.last_triggered_at DESC
 LIMIT $`+strconv.Itoa(len(args)-1)+` OFFSET $`+strconv.Itoa(len(args)), args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []dom.Alert
	var total int64
	for rows.Next() {
		var a dom.Alert
		var ctxBytes []byte
		if err := rows.Scan(&a.ID, &a.UUID, &a.ScopeKind, &a.TenantID, &a.SourceKind, &a.AlertType, &a.Severity,
			&a.Status, &a.Fingerprint, &a.Title, &a.Summary, &a.ResourceKind, &a.ResourceUUID,
			&a.FirstTriggeredAt, &a.LastTriggeredAt, &a.OccurrenceCount,
			&a.AcknowledgedBy, &a.AcknowledgedAt, &a.ResolvedAt, &a.ResolvedBy, &ctxBytes, &a.CreatedAt, &a.UpdatedAt,
			&a.TenantName, &total); err != nil {
			return nil, 0, err
		}
		if len(ctxBytes) > 0 {
			_ = json.Unmarshal(ctxBytes, &a.Context)
		}
		if a.Context == nil {
			a.Context = map[string]any{}
		}
		out = append(out, a)
	}
	return out, total, rows.Err()
}

func prefixCols(p string) string {
	return p + `.id, ` + p + `.uuid, ` + p + `.scope_kind, ` + p + `.tenant_id, ` + p + `.source_kind, ` + p + `.alert_type, ` + p + `.severity, ` + p + `.status, ` + p + `.fingerprint,
    ` + p + `.title, ` + p + `.summary, ` + p + `.resource_kind, ` + p + `.resource_uuid, ` + p + `.first_triggered_at, ` + p + `.last_triggered_at, ` + p + `.occurrence_count,
    ` + p + `.acknowledged_by, ` + p + `.acknowledged_at, ` + p + `.resolved_at, ` + p + `.resolved_by, ` + p + `.context, ` + p + `.created_at, ` + p + `.updated_at`
}

func tenantOnlyCond(tenantOnly *int64, args *[]any) string {
	if tenantOnly == nil {
		return ``
	}
	*args = append(*args, *tenantOnly)
	return ` AND scope_kind='tenant' AND tenant_id=$` + strconv.Itoa(len(*args))
}

// GetByUUID 详情。
func (r *Repo) GetByUUID(ctx context.Context, uuid string, tenantOnly *int64) (*dom.Alert, error) {
	args := []any{uuid}
	cond := tenantOnlyCond(tenantOnly, &args)
	a, err := scanAlert(r.pool.QueryRow(ctx, `SELECT `+alertCols+` FROM alerts WHERE uuid=$1`+cond, args...))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.New(apperr.NotFound, "alert.not_found")
		}
		return nil, err
	}
	return a, nil
}

// CountFiring 铃铛计数。平台侧（tenantOnly=nil）排除租户经营类告警（与平台待处理视图口径一致）。
func (r *Repo) CountFiring(ctx context.Context, tenantOnly *int64) (int64, error) {
	args := []any{}
	cond := tenantOnlyCond(tenantOnly, &args)
	if tenantOnly == nil {
		args = append(args, dom.TenantOpsAlertTypes)
		cond += ` AND NOT (alert_type = ANY($` + strconv.Itoa(len(args)) + `))`
	}
	var n int64
	err := r.pool.QueryRow(ctx, `SELECT count(*) FROM alerts WHERE status='firing'`+cond, args...).Scan(&n)
	return n, err
}

// Acknowledge firing→acknowledged。
func (r *Repo) Acknowledge(ctx context.Context, uuid string, tenantOnly *int64, by int64) (*dom.Alert, error) {
	args := []any{uuid, by}
	cond := tenantOnlyCond(tenantOnly, &args)
	a, err := scanAlert(r.pool.QueryRow(ctx, `
UPDATE alerts SET status='acknowledged', acknowledged_by=$2, acknowledged_at=now(), updated_at=now()
 WHERE uuid=$1 AND status='firing'`+cond+` RETURNING `+alertCols, args...))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, r.ackConflictOrNotFound(ctx, uuid, tenantOnly)
		}
		return nil, err
	}
	return a, nil
}

func (r *Repo) ackConflictOrNotFound(ctx context.Context, uuid string, tenantOnly *int64) error {
	if _, err := r.GetByUUID(ctx, uuid, tenantOnly); err != nil {
		return err // not_found（含跨租户不泄漏语义）
	}
	return apperr.New(apperr.Conflict, "alert.status_conflict")
}

// ResolveManual 人工恢复：告警行 + notify.alert.resolved outbox 同事务。
func (r *Repo) ResolveManual(ctx context.Context, uuid string, tenantOnly *int64, by int64) (*dom.Alert, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	args := []any{uuid, by}
	cond := tenantOnlyCond(tenantOnly, &args)
	a, err := scanAlert(tx.QueryRow(ctx, `
UPDATE alerts SET status='resolved', resolved_by=$2, resolved_at=now(), updated_at=now()
 WHERE uuid=$1 AND status IN ('firing','acknowledged')`+cond+` RETURNING `+alertCols, args...))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, r.ackConflictOrNotFound(ctx, uuid, tenantOnly)
		}
		return nil, err
	}
	if err := r.publishTransition(ctx, tx, a, "notify.alert.resolved"); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return a, nil
}

// UpsertFiring 评估器命中：无未恢复行则新建 firing + 发 notify.alert.fired；有则累加。
func (r *Repo) UpsertFiring(ctx context.Context, c dom.Candidate) (bool, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	ctxBytes, err := json.Marshal(sanitizeContext(c.Context))
	if err != nil {
		return false, err
	}
	// partial unique (fingerprint) WHERE status<>'resolved' 不能用 ON CONFLICT 的裸列推断，
	// 这里显式两步（同事务内无并发写者：评估器单飞）。
	var existingID int64
	err = tx.QueryRow(ctx, `SELECT id FROM alerts WHERE fingerprint=$1 AND status<>'resolved'`, c.Fingerprint()).Scan(&existingID)
	switch {
	case err == nil:
		_, err = tx.Exec(ctx, `
UPDATE alerts SET occurrence_count=occurrence_count+1, last_triggered_at=now(),
       severity=$2, summary=$3, context=$4::jsonb, updated_at=now()
 WHERE id=$1`, existingID, c.Severity, c.Summary, string(ctxBytes))
		if err != nil {
			return false, err
		}
		return false, tx.Commit(ctx)
	case errors.Is(err, pgx.ErrNoRows):
		a, err := scanAlert(tx.QueryRow(ctx, `
INSERT INTO alerts (scope_kind, tenant_id, source_kind, alert_type, severity, status, fingerprint,
                    title, summary, resource_kind, resource_uuid, context)
VALUES ($1,$2,$3,$4,$5,'firing',$6,$7,$8,$9,$10,$11::jsonb)
RETURNING `+alertCols,
			c.ScopeKind, c.TenantID, c.SourceKind, c.AlertType, c.Severity, c.Fingerprint(),
			c.Title, c.Summary, c.ResourceKind, c.ResourceUUID, string(ctxBytes)))
		if err != nil {
			return false, err
		}
		if err := r.publishTransition(ctx, tx, a, "notify.alert.fired"); err != nil {
			return false, err
		}
		return true, tx.Commit(ctx)
	default:
		return false, err
	}
}

// AutoResolve 评估器自动恢复。
func (r *Repo) AutoResolve(ctx context.Context, fingerprint string) (bool, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	a, err := scanAlert(tx.QueryRow(ctx, `
UPDATE alerts SET status='resolved', resolved_at=now(), updated_at=now()
 WHERE fingerprint=$1 AND status<>'resolved' RETURNING `+alertCols, fingerprint))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, tx.Commit(ctx)
		}
		return false, err
	}
	if err := r.publishTransition(ctx, tx, a, "notify.alert.resolved"); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

// outboxTenantID 决定 notify.alert.* outbox 行的租户归属（F25 评审返修，租户隔离边界）：
// webhook 分发按 outbox.tenant_id fan-out 到该租户的 webhook——
// 平台 scope 告警（即使带租户归属，如 order_unfulfilled）不得外发给租户，一律 0（仅留痕）；
// 只有 scope_kind=tenant 才携带租户 ID。回归测试见 repo_test.go。
func outboxTenantID(a *dom.Alert) int64 {
	if a.ScopeKind == dom.ScopeTenant && a.TenantID != nil {
		return *a.TenantID
	}
	return 0
}

// publishTransition 在事务内写 notify.alert.* outbox；平台级告警 tenant_id=0（无租户 webhook 目标，仅留痕）。
func (r *Repo) publishTransition(ctx context.Context, tx pgx.Tx, a *dom.Alert, topic string) error {
	if r.pub == nil {
		return nil
	}
	tenantID := outboxTenantID(a)
	payload, err := json.Marshal(map[string]any{
		"alert_uuid":         a.UUID,
		"alert_type":         a.AlertType,
		"severity":           a.Severity,
		"scope_kind":         a.ScopeKind,
		"tenant_id":          a.TenantID,
		"status":             a.Status,
		"title":              a.Title,
		"summary":            a.Summary,
		"resource_kind":      a.ResourceKind,
		"resource_uuid":      a.ResourceUUID,
		"first_triggered_at": a.FirstTriggeredAt.Format(time.RFC3339),
		"occurrence_count":   a.OccurrenceCount,
	})
	if err != nil {
		return err
	}
	err = r.pub.Publish(ctx, evtrepo.WrapTx(tx), domevent.Event{
		Topic:          topic,
		TenantID:       tenantID,
		IdempotencyKey: fmt.Sprintf("alert:%s:%s", a.UUID, a.Status),
		Payload:        payload,
	})
	if errors.Is(err, domevent.ErrDuplicate) {
		return nil
	}
	return err
}

// contextKeyWhitelist 是 alerts.context 允许写入的键（F25 §2.1：禁止正文/密钥；写入侧强制）。
var contextKeyWhitelist = map[string]bool{
	"observed": true, "threshold": true, "window": true, "unit": true,
	"total": true, "failed": true, "rate": true, "p95_ms": true,
	"feature_code": true, "job_uuid": true, "job_name": true, "provider_uuid": true, "provider_name": true,
	"instance_uuid": true, "runtime_environment_id": true, "order_no": true, "period_end": true,
	"last_error": true,
	"balance":    true, "available": true, "used_pct": true, "pending": true, "dlq": true, "backlog": true,
}

func sanitizeContext(in map[string]any) map[string]any {
	out := map[string]any{}
	for k, v := range in {
		if contextKeyWhitelist[k] {
			out[k] = v
		}
	}
	return out
}

// ---- 评估器连击状态 ----

// BumpRuleState 命中/未命中各自累加并清零对侧。
func (r *Repo) BumpRuleState(ctx context.Context, ruleKey, resourceKey string, hit bool) (int, int, error) {
	var hits, misses int
	var err error
	if hit {
		err = r.pool.QueryRow(ctx, `
INSERT INTO alert_rule_state (rule_key, resource_key, consecutive_hits, consecutive_misses, last_evaluated_at)
VALUES ($1,$2,1,0,now())
ON CONFLICT (rule_key, resource_key)
DO UPDATE SET consecutive_hits=alert_rule_state.consecutive_hits+1, consecutive_misses=0, last_evaluated_at=now()
RETURNING consecutive_hits, consecutive_misses`, ruleKey, resourceKey).Scan(&hits, &misses)
	} else {
		err = r.pool.QueryRow(ctx, `
UPDATE alert_rule_state SET consecutive_misses=consecutive_misses+1, consecutive_hits=0, last_evaluated_at=now()
 WHERE rule_key=$1 AND resource_key=$2
RETURNING consecutive_hits, consecutive_misses`, ruleKey, resourceKey).Scan(&hits, &misses)
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, 0, nil
		}
	}
	return hits, misses, err
}

// ListRuleStateResources 某规则当前跟踪的 resource_key 集合。
func (r *Repo) ListRuleStateResources(ctx context.Context, ruleKey string) ([]string, error) {
	rows, err := r.pool.Query(ctx, `SELECT resource_key FROM alert_rule_state WHERE rule_key=$1`, ruleKey)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

// ClearRuleState 恢复后清理。
func (r *Repo) ClearRuleState(ctx context.Context, ruleKey, resourceKey string) error {
	_, err := r.pool.Exec(ctx, `DELETE FROM alert_rule_state WHERE rule_key=$1 AND resource_key=$2`, ruleKey, resourceKey)
	return err
}
