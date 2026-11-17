// Package platform 提供后台用的"平台/租户全景数据"查询服务。
//
// 主要用途：
//   - Dashboard 卡片（计数）
//   - Runtime / EMP / Composer Skill / Conversation 列表（admin 后台浏览）
//
// 注意：这一层做的是"聚合 + 读"，不做写。写操作走对应业务 service。
package platform

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// PlatformStats Dashboard 用。
type PlatformStats struct {
	Tenants       int64 `json:"tenants"`
	ActiveTenants int64 `json:"active_tenants"`
	Runtimes      int64 `json:"runtimes"`
	EMPBlocks     int64 `json:"emp_blocks"`
	// Accounts 2026-08-24 改口径: 有 >=1 条当前生效 tenant_membership 的账号数
	// (distinct account_id), 不再是 accounts 表未软删总行数。原口径在接了
	// 宜信 MIS 组织架构同步的环境里严重失真——missync 的 prune-departments /
	// 离职同步只软删 tenant_memberships/role_assignments, 明确"从不碰 accounts
	// 表", 账号一旦被同步进来过就永远留在 accounts 表里, 哪怕人早就离职了;
	// 再叠加自助注册的测试账号, accounts 表总数会远超真实在职人数(某环境实测
	// 1602 vs 实际约 199 人)。改成看 tenant_membership 更贴近"现在真的在某个
	// 租户里的人"。
	Accounts      int64 `json:"accounts"`
	DigitalEmps   int64 `json:"digital_employees"`
	ConvosToday   int64 `json:"conversations_today"`
	MessagesToday int64 `json:"messages_today"`
}

// PlatformOverview 平台首页聚合 (F25 §4.2)：既有 PlatformStats + 平台健康 + Top5 待处理告警。
// 固定 2 次 DB 往返（标量合并单查询 + Top 告警）。
type PlatformOverview struct {
	PlatformStats
	Health    PlatformHealth     `json:"health"`
	TopAlerts []PlatformTopAlert `json:"top_alerts"`
}

// PlatformHealth 平台健康区块。口径见 F25 §4.2：
//   - runsToday* 直查 agent_runs 当日窗口（F24 表）；successRate 分母 0 时为 null；
//   - affectedTenants = 存在 firing 告警的去重租户数；
//   - providersAbnormal = 未恢复的 kb_provider_unhealthy 告警数（评估器探活结论，避免首页发探测 HTTP）。
type PlatformHealth struct {
	RunsToday          int64    `json:"runs_today"`
	RunsFailedToday    int64    `json:"runs_failed_today"`
	SuccessRate        *float64 `json:"success_rate"`
	P95DurationMs      *int64   `json:"p95_duration_ms"`
	AffectedTenants    int64    `json:"affected_tenants"`
	InstancesAbnormal  int64    `json:"instances_abnormal"`
	ProvidersAbnormal  int64    `json:"providers_abnormal"`
	CronErrorJobs      int64    `json:"cron_error_jobs"`
	DriveWorkerBacklog int64    `json:"drive_worker_backlog"`
	OutboxBacklog      int64    `json:"outbox_backlog"`
}

// PlatformTopAlert 首页「待处理告警」条目（firing，按严重度+时间排序 Top5）。
type PlatformTopAlert struct {
	UUID            string `json:"uuid"`
	Severity        string `json:"severity"`
	Title           string `json:"title"`
	SourceKind      string `json:"source_kind"`
	AlertType       string `json:"alert_type"`
	TenantID        *int64 `json:"tenant_id"`
	TenantName      string `json:"tenant_name"`
	LastTriggeredAt string `json:"last_triggered_at"`
	OccurrenceCount int    `json:"occurrence_count"`
}

// TenantInsight 平台侧租户 360° 聚合 (F25 §4.3)：复用 TenantOverview 全量 + run 统计 + 告警计数。
// 共 4 次 DB 往返（TenantOverview 3 + insight 标量 1）。
type TenantInsight struct {
	Overview         *TenantOverview `json:"overview"`
	RunStats         TenantRunStats  `json:"run_stats"`
	ActiveMembers30d int64           `json:"active_members_30d"`
	OpenAlerts       int64           `json:"open_alerts"`
}

// TenantRunStats 近 14 天 agent_runs 统计（F24 表）。
type TenantRunStats struct {
	Runs14d       int64    `json:"runs_14d"`
	Failed14d     int64    `json:"failed_14d"`
	SuccessRate   *float64 `json:"success_rate"`
	P95DurationMs *int64   `json:"p95_duration_ms"`
}

// TenantStats Dashboard 用 (单租户)。
type TenantStats struct {
	Members          int64 `json:"members"`
	Departments      int64 `json:"departments"`
	DigitalEmployees int64 `json:"digital_employees"`
	Published        int64 `json:"published"`
	Conversations    int64 `json:"conversations"`
	MessagesToday    int64 `json:"messages_today"`
}

// TenantOverview 租户控制台概览聚合 (F23)。
// 字段口径与分区块含义见 docs/features/F23-tenant-console-overview.md。
type TenantOverview struct {
	TenantStats
	ConversationsToday int64              `json:"conversations_today"`
	ActiveMembers7d    int64              `json:"active_members_7d"`
	KBCount            int64              `json:"kb_count"`
	Billing            *TenantBilling     `json:"billing"`
	Health             TenantHealth       `json:"health"`
	Todos              TenantTodos        `json:"todos"`
	Trend              []TenantTrendPoint `json:"trend"`
	TopAgents          []TenantTopAgent   `json:"top_agents"`
}

// TenantBilling 概览成本卡; 租户未开通计费(无订阅且无钱包)时整体为 null。
type TenantBilling struct {
	PlanName           string `json:"plan_name"`
	SubscriptionStatus string `json:"subscription_status"`
	PeriodEnd          string `json:"period_end"`
	CreditBalance      int64  `json:"credit_balance"`
	WalletFrozen       bool   `json:"wallet_frozen"`
	MonthCreditsUsed   int64  `json:"month_credits_used"`
}

// TenantHealth 概览健康卡 (F19 调用日志 + runtime_instances)。
type TenantHealth struct {
	Calls24h          int64 `json:"calls_24h"`
	CallsFailed24h    int64 `json:"calls_failed_24h"`
	InstancesTotal    int64 `json:"instances_total"`
	InstancesReady    int64 `json:"instances_ready"`
	InstancesAbnormal int64 `json:"instances_abnormal"`
}

// TenantTodos 概览待办计数; 只统计需要管理员处理的当前态。
type TenantTodos struct {
	DraftAgents       int64 `json:"draft_agents"`
	CronErrors        int64 `json:"cron_errors"`
	KBIngestFailed7d  int64 `json:"kb_ingest_failed_7d"`
	InstancesAbnormal int64 `json:"instances_abnormal"`
	// F25 增量: 未处理告警(firing) 与待审批件(pending), 概览待办区下钻入口。
	AlertsFiring     int64 `json:"alerts_firing"`
	ApprovalsPending int64 `json:"approvals_pending"`
}

// TenantTrendPoint 近 14 天单日用量点(自然日补 0, 旧→新)。
type TenantTrendPoint struct {
	Date           string `json:"date"`
	UserMessages   int64  `json:"user_messages"`
	AgentMessages  int64  `json:"agent_messages"`
	ActiveAccounts int64  `json:"active_accounts"`
}

// TenantTopAgent 近 7 天最活跃数字员工。
type TenantTopAgent struct {
	Name            string `json:"name"`
	Conversations7d int64  `json:"conversations_7d"`
	Messages7d      int64  `json:"messages_7d"`
	Users7d         int64  `json:"users_7d"`
}

// Runtime 列表 DTO。
type Runtime struct {
	ID                int64          `json:"id"`
	Code              string         `json:"code"`
	Name              string         `json:"name"`
	Description       string         `json:"description,omitempty"`
	Framework         string         `json:"framework,omitempty"`
	AdapterKind       string         `json:"adapter_kind"`
	Endpoints         map[string]any `json:"endpoints,omitempty"`
	DataEgress        string         `json:"data_egress"`
	EgressAuditStatus string         `json:"egress_audit_status"`
	Status            string         `json:"status"`
	LastHealthyAt     string         `json:"last_healthy_at,omitempty"`
	InstanceCount     int64          `json:"instance_count"`
	UsedByAgents      int64          `json:"used_by_agents"`
}

// (EMPBlock DTO 已迁出: 见 internal/domain/empblock.Block + internal/service/emp.Service.)

// RecentConv Dashboard "最近会话" 用。
type RecentConv struct {
	UUID         string `json:"uuid"`
	Title        string `json:"title"`
	AgentName    string `json:"agent_name"`
	AccountName  string `json:"account_name"`
	LastAt       string `json:"last_at"`
	MessageCount int    `json:"message_count"`
}

// Plan 套餐 DTO（简版）。
type Plan struct {
	ID           int64   `json:"id"`
	Code         string  `json:"code"`
	Name         string  `json:"name"`
	Description  string  `json:"description,omitempty"`
	PriceMonthly float64 `json:"price_monthly"`
	Currency     string  `json:"currency"`
	IsActive     bool    `json:"is_active"`
	IsSystem     bool    `json:"is_system"`
}

// Service 接口。
type Service interface {
	PlatformStats(ctx context.Context) (*PlatformStats, error)
	// PlatformOverview 平台首页单接口聚合 (F25); 固定 2 次 DB 往返。
	PlatformOverview(ctx context.Context) (*PlatformOverview, error)
	TenantStats(ctx context.Context, tenantID int64) (*TenantStats, error)
	// TenantOverview 概览页单接口聚合 (F23); 固定 3 次 DB 往返。
	TenantOverview(ctx context.Context, tenantID int64) (*TenantOverview, error)
	// TenantInsight 平台侧租户 360° 聚合 (F25); TenantOverview + run 统计 + 告警计数。
	TenantInsight(ctx context.Context, tenantID int64) (*TenantInsight, error)
	ListRuntimes(ctx context.Context) ([]Runtime, error)
	// ListEMPBlocks 已迁出: admin EMP 列表统一走 internal/service/emp.Service.List (3D Codex 二次返修 #3).
	RecentConversations(ctx context.Context, tenantID int64, limit int) ([]RecentConv, error)
	ListPlans(ctx context.Context) ([]Plan, error)
	// M3 §6.3 平台预置能力池, kind ∈ composer_skill / background_skill / mcp / knowledge_base。
	CapabilityCatalog(ctx context.Context, tenantID int64, kind string) ([]CatalogItem, error)
}

// CatalogItem 是平台预置能力的统一卡片。
type CatalogItem struct {
	Kind        string `json:"kind"`
	UUID        string `json:"uuid"`
	Code        string `json:"code,omitempty"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Vendor      string `json:"vendor,omitempty"`
	Category    string `json:"category,omitempty"`
}

type impl struct {
	pool           *pgxpool.Pool
	includeBilling bool
}

func New(pool *pgxpool.Pool) Service { return &impl{pool: pool, includeBilling: true} }

// NewCommunity keeps shared operational statistics independent of unexported commercial billing tables.
func NewCommunity(pool *pgxpool.Pool) Service { return &impl{pool: pool} }

func (s *impl) PlatformStats(ctx context.Context) (*PlatformStats, error) {
	st := &PlatformStats{}
	q := `
		SELECT
		  (SELECT count(*) FROM tenants WHERE deleted_at IS NULL),
		  (SELECT count(*) FROM tenants WHERE deleted_at IS NULL AND status='active'),
		  (SELECT count(*) FROM runtime_environments WHERE is_deleted = false),
		  (SELECT count(*) FROM emp_block_registry),
		  (SELECT count(DISTINCT tm.account_id)
		     FROM tenant_memberships tm
		     JOIN accounts a ON a.id = tm.account_id
		    WHERE tm.deleted_at IS NULL AND tm.status='active' AND a.deleted_at IS NULL),
		  (SELECT count(*) FROM digital_employees WHERE deleted_at IS NULL),
		  (SELECT count(*) FROM conversations WHERE deleted_at IS NULL AND created_at >= now()::date),
		  (SELECT count(*) FROM messages WHERE created_at >= now()::date)
	`
	if err := s.pool.QueryRow(ctx, q).Scan(
		&st.Tenants, &st.ActiveTenants, &st.Runtimes, &st.EMPBlocks,
		&st.Accounts, &st.DigitalEmps, &st.ConvosToday, &st.MessagesToday,
	); err != nil {
		return nil, err
	}
	return st, nil
}

// TenantInsight 平台侧租户 360° 聚合 (F25 §4.3)。
func (s *impl) TenantInsight(ctx context.Context, tenantID int64) (*TenantInsight, error) {
	overview, err := s.TenantOverview(ctx, tenantID)
	if err != nil {
		return nil, err
	}
	in := &TenantInsight{Overview: overview}
	var p95 *float64
	q := `
		SELECT
		  (SELECT count(*) FROM agent_runs WHERE tenant_id=$1 AND started_at >= now() - interval '14 days'),
		  (SELECT count(*) FROM agent_runs WHERE tenant_id=$1 AND started_at >= now() - interval '14 days' AND status='failed'),
		  (SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms)
		     FROM agent_runs WHERE tenant_id=$1 AND started_at >= now() - interval '14 days' AND duration_ms IS NOT NULL),
		  (SELECT count(DISTINCT sender_account_id) FROM messages
		    WHERE tenant_id=$1 AND role='user' AND sender_account_id IS NOT NULL
		      AND created_at >= now() - interval '30 days'),
		  (SELECT count(*) FROM alerts WHERE scope_kind='tenant' AND tenant_id=$1 AND status <> 'resolved')
	`
	if err := s.pool.QueryRow(ctx, q, tenantID).Scan(
		&in.RunStats.Runs14d, &in.RunStats.Failed14d, &p95,
		&in.ActiveMembers30d, &in.OpenAlerts,
	); err != nil {
		return nil, err
	}
	if p95 != nil {
		v := int64(*p95)
		in.RunStats.P95DurationMs = &v
	}
	if in.RunStats.Runs14d > 0 {
		rate := float64(in.RunStats.Runs14d-in.RunStats.Failed14d) / float64(in.RunStats.Runs14d) * 100
		in.RunStats.SuccessRate = &rate
	}
	return in, nil
}

// PlatformOverview 平台首页聚合 (F25)。标量全部合并进一条查询（远程库单条 SQL 延迟高, 见 pitfalls），
// Top 告警单独一条，共 2 次往返。provider 健康取评估器结论（alerts 表），首页不发探测 HTTP。
func (s *impl) PlatformOverview(ctx context.Context) (*PlatformOverview, error) {
	o := &PlatformOverview{TopAlerts: []PlatformTopAlert{}}
	var p95 *float64
	scalarQ := `
		SELECT
		  (SELECT count(*) FROM tenants WHERE deleted_at IS NULL),
		  (SELECT count(*) FROM tenants WHERE deleted_at IS NULL AND status='active'),
		  (SELECT count(*) FROM runtime_environments WHERE is_deleted = false),
		  (SELECT count(*) FROM emp_block_registry),
		  (SELECT count(DISTINCT tm.account_id)
		     FROM tenant_memberships tm
		     JOIN accounts a ON a.id = tm.account_id
		    WHERE tm.deleted_at IS NULL AND tm.status='active' AND a.deleted_at IS NULL),
		  (SELECT count(*) FROM digital_employees WHERE deleted_at IS NULL),
		  (SELECT count(*) FROM conversations WHERE deleted_at IS NULL AND created_at >= now()::date),
		  (SELECT count(*) FROM messages WHERE created_at >= now()::date),
		  (SELECT count(*) FROM agent_runs WHERE started_at >= now()::date),
		  (SELECT count(*) FROM agent_runs WHERE started_at >= now()::date AND status='failed'),
		  (SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms)
		     FROM agent_runs WHERE started_at >= now()::date AND duration_ms IS NOT NULL),
		  (SELECT count(DISTINCT tenant_id) FROM alerts WHERE status='firing' AND tenant_id IS NOT NULL
		     AND NOT (alert_type = ANY(ARRAY['quota_threshold','credit_low','subscription_expiring']))),
		  (SELECT count(*) FROM runtime_instances WHERE is_deleted=false AND status IN ('failed','degraded')),
		  (SELECT count(*) FROM alerts WHERE alert_type='kb_provider_unhealthy' AND status <> 'resolved'),
		  (SELECT count(*) FROM agent_cron_jobs WHERE status='error' AND deleted_at IS NULL),
		  (SELECT count(*) FROM drive_worker_job_status WHERE enabled=true AND (status='failed' OR consecutive_failures >= 3)),
		  (SELECT count(*) FROM events_outbox WHERE status='failed')
		  + (SELECT count(*) FROM events_outbox_dlq WHERE dlq_at >= now() - interval '24 hours')
	`
	if err := s.pool.QueryRow(ctx, scalarQ).Scan(
		&o.Tenants, &o.ActiveTenants, &o.Runtimes, &o.EMPBlocks,
		&o.Accounts, &o.DigitalEmps, &o.ConvosToday, &o.MessagesToday,
		&o.Health.RunsToday, &o.Health.RunsFailedToday, &p95,
		&o.Health.AffectedTenants, &o.Health.InstancesAbnormal, &o.Health.ProvidersAbnormal,
		&o.Health.CronErrorJobs, &o.Health.DriveWorkerBacklog, &o.Health.OutboxBacklog,
	); err != nil {
		return nil, err
	}
	if p95 != nil {
		v := int64(*p95)
		o.Health.P95DurationMs = &v
	}
	if o.Health.RunsToday > 0 {
		rate := float64(o.Health.RunsToday-o.Health.RunsFailedToday) / float64(o.Health.RunsToday) * 100
		o.Health.SuccessRate = &rate
	}

	rows, err := s.pool.Query(ctx, `
		SELECT a.uuid, a.severity, a.title, a.source_kind, a.alert_type, a.tenant_id, COALESCE(t.name,''),
		       a.last_triggered_at, a.occurrence_count
		  FROM alerts a
		  LEFT JOIN tenants t ON t.id = a.tenant_id
		 WHERE a.status = 'firing'
		   AND NOT (a.alert_type = ANY(ARRAY['quota_threshold','credit_low','subscription_expiring']))
		 ORDER BY CASE a.severity WHEN 'critical' THEN 0 ELSE 1 END, a.last_triggered_at DESC
		 LIMIT 5`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var it PlatformTopAlert
		var lastAt time.Time
		if err := rows.Scan(&it.UUID, &it.Severity, &it.Title, &it.SourceKind, &it.AlertType,
			&it.TenantID, &it.TenantName, &lastAt, &it.OccurrenceCount); err != nil {
			return nil, err
		}
		it.LastTriggeredAt = lastAt.Format(time.RFC3339)
		o.TopAlerts = append(o.TopAlerts, it)
	}
	return o, rows.Err()
}

func (s *impl) TenantStats(ctx context.Context, tenantID int64) (*TenantStats, error) {
	st := &TenantStats{}
	q := `
		SELECT
		  (SELECT count(*) FROM tenant_memberships WHERE tenant_id=$1 AND deleted_at IS NULL),
		  (SELECT count(*) FROM departments WHERE tenant_id=$1 AND deleted_at IS NULL),
		  (SELECT count(*) FROM digital_employees WHERE tenant_id=$1 AND deleted_at IS NULL),
		  (SELECT count(*) FROM digital_employees WHERE tenant_id=$1 AND deleted_at IS NULL AND status='published'),
		  (SELECT count(*) FROM conversations WHERE tenant_id=$1 AND deleted_at IS NULL),
		  (SELECT count(*) FROM messages WHERE tenant_id=$1 AND created_at >= now()::date)
	`
	if err := s.pool.QueryRow(ctx, q, tenantID).Scan(
		&st.Members, &st.Departments, &st.DigitalEmployees,
		&st.Published, &st.Conversations, &st.MessagesToday,
	); err != nil {
		return nil, err
	}
	return st, nil
}

// TenantOverview 概览聚合 (F23)。远程库单条 SQL 延迟高(见 pitfalls),
// 所以所有标量合并进一条查询, 趋势/Top榜各一条, 共 3 次往返。
func (s *impl) TenantOverview(ctx context.Context, tenantID int64) (*TenantOverview, error) {
	o := &TenantOverview{Trend: []TenantTrendPoint{}, TopAgents: []TenantTopAgent{}}

	// ---- 1. 标量: 存量/今日/活跃/待办/健康/计费 ----
	var (
		monthUsed                      int64
		planName, subStatus, periodEnd *string
		balance                        *int64
		frozen                         *bool
	)
	billingQuery := ""
	billingTargets := []any{}
	if s.includeBilling {
		billingQuery = `
		  (SELECT p.name FROM subscriptions s JOIN plans p ON p.id = s.plan_id
		    WHERE s.tenant_id=$1 AND s.status IN ('trialing','active','past_due') LIMIT 1),
		  (SELECT s.status FROM subscriptions s
		    WHERE s.tenant_id=$1 AND s.status IN ('trialing','active','past_due') LIMIT 1),
		  (SELECT to_char(s.current_period_end, 'YYYY-MM-DD') FROM subscriptions s
		    WHERE s.tenant_id=$1 AND s.status IN ('trialing','active','past_due') LIMIT 1),
		  (SELECT balance FROM credit_wallets WHERE tenant_id=$1),
		  (SELECT frozen FROM credit_wallets WHERE tenant_id=$1),
		  (SELECT COALESCE(sum(total_credits), 0) FROM usage_aggregates
		    WHERE tenant_id=$1 AND period='monthly' AND period_start = date_trunc('month', now())::date),
`
		billingTargets = []any{&planName, &subStatus, &periodEnd, &balance, &frozen, &monthUsed}
	}
	scalarQ := `
		SELECT
		  (SELECT count(*) FROM tenant_memberships WHERE tenant_id=$1 AND deleted_at IS NULL),
		  (SELECT count(*) FROM departments WHERE tenant_id=$1 AND deleted_at IS NULL),
		  (SELECT count(*) FROM digital_employees WHERE tenant_id=$1 AND deleted_at IS NULL),
		  (SELECT count(*) FROM digital_employees WHERE tenant_id=$1 AND deleted_at IS NULL AND status='published'),
		  (SELECT count(*) FROM conversations WHERE tenant_id=$1 AND deleted_at IS NULL),
		  (SELECT count(*) FROM messages WHERE tenant_id=$1 AND created_at >= now()::date),
		  (SELECT count(*) FROM conversations WHERE tenant_id=$1 AND deleted_at IS NULL AND created_at >= now()::date),
		  (SELECT count(DISTINCT sender_account_id) FROM messages
		    WHERE tenant_id=$1 AND role='user' AND sender_account_id IS NOT NULL
		      AND created_at >= now() - interval '7 days'),
		  (SELECT count(*) FROM knowledge_bases WHERE tenant_id=$1 AND deleted_at IS NULL),
		  (SELECT count(*) FROM digital_employees WHERE tenant_id=$1 AND deleted_at IS NULL AND status='draft'),
		  (SELECT count(*) FROM agent_cron_jobs WHERE tenant_id=$1 AND deleted_at IS NULL AND status='error'),
		  (SELECT count(*) FROM kb_ingest_jobs j JOIN knowledge_bases k ON k.id = j.kb_id
		    WHERE k.tenant_id=$1 AND k.deleted_at IS NULL AND j.status='failed'
		      AND j.created_at >= now() - interval '7 days'),
		  (SELECT count(*) FROM runtime_instances WHERE tenant_id=$1 AND is_deleted=false),
		  (SELECT count(*) FROM runtime_instances WHERE tenant_id=$1 AND is_deleted=false AND status='ready'),
		  (SELECT count(*) FROM runtime_instances WHERE tenant_id=$1 AND is_deleted=false AND status IN ('failed','degraded')),
		  (SELECT count(*) FROM runtime_call_logs WHERE tenant_id=$1 AND created_at >= now() - interval '24 hours'),
		  (SELECT count(*) FROM runtime_call_logs
		    WHERE tenant_id=$1 AND created_at >= now() - interval '24 hours'
		      AND (http_status >= 400 OR (http_status IS NULL AND COALESCE(error_message,'') <> ''))),
` + billingQuery + `
		  (SELECT count(*) FROM alerts WHERE scope_kind='tenant' AND tenant_id=$1 AND status='firing'),
		  (SELECT count(*) FROM a2a_approval_requests WHERE tenant_id=$1 AND status='pending')
	`
	targets := []any{
		&o.Members, &o.Departments, &o.DigitalEmployees, &o.Published,
		&o.Conversations, &o.MessagesToday, &o.ConversationsToday,
		&o.ActiveMembers7d, &o.KBCount,
		&o.Todos.DraftAgents, &o.Todos.CronErrors, &o.Todos.KBIngestFailed7d,
		&o.Health.InstancesTotal, &o.Health.InstancesReady, &o.Health.InstancesAbnormal,
		&o.Health.Calls24h, &o.Health.CallsFailed24h,
	}
	targets = append(targets, billingTargets...)
	targets = append(targets, &o.Todos.AlertsFiring, &o.Todos.ApprovalsPending)
	if err := s.pool.QueryRow(ctx, scalarQ, tenantID).Scan(targets...); err != nil {
		return nil, err
	}
	o.Todos.InstancesAbnormal = o.Health.InstancesAbnormal
	if planName != nil || balance != nil {
		b := &TenantBilling{MonthCreditsUsed: monthUsed}
		if planName != nil {
			b.PlanName = *planName
		}
		if subStatus != nil {
			b.SubscriptionStatus = *subStatus
		}
		if periodEnd != nil {
			b.PeriodEnd = *periodEnd
		}
		if balance != nil {
			b.CreditBalance = *balance
		}
		if frozen != nil {
			b.WalletFrozen = *frozen
		}
		o.Billing = b
	}

	// ---- 2. 近 14 天趋势(自然日补 0) ----
	trendRows, err := s.pool.Query(ctx, `
		SELECT to_char(d, 'MM-DD'),
		       COALESCE(m.user_msgs, 0), COALESCE(m.agent_msgs, 0), COALESCE(m.actives, 0)
		FROM generate_series(now()::date - 13, now()::date, interval '1 day') AS d
		LEFT JOIN (
		  SELECT m.created_at::date AS day,
		         count(*) FILTER (WHERE m.role='user')  AS user_msgs,
		         count(*) FILTER (WHERE m.role='agent') AS agent_msgs,
		         count(DISTINCT m.sender_account_id) FILTER (WHERE m.role='user') AS actives
		  FROM messages m
		  JOIN conversations c ON c.id = m.conversation_id
		  WHERE m.tenant_id=$1 AND c.tenant_id=$1 AND c.deleted_at IS NULL
		    AND c.digital_employee_id IS NOT NULL
		    AND m.created_at >= now()::date - 13
		  GROUP BY 1
		) m ON m.day = d::date
		ORDER BY d`, tenantID)
	if err != nil {
		return nil, err
	}
	defer trendRows.Close()
	for trendRows.Next() {
		var p TenantTrendPoint
		if err := trendRows.Scan(&p.Date, &p.UserMessages, &p.AgentMessages, &p.ActiveAccounts); err != nil {
			return nil, err
		}
		o.Trend = append(o.Trend, p)
	}
	if err := trendRows.Err(); err != nil {
		return nil, err
	}

	// ---- 3. 近 7 天最活跃数字员工 Top5 ----
	topRows, err := s.pool.Query(ctx, `
		SELECT COALESCE(de.name, '已删除员工'),
		       count(DISTINCT c.id),
		       count(*),
		       count(DISTINCT m.sender_account_id) FILTER (WHERE m.role='user')
		FROM messages m
		JOIN conversations c ON c.id = m.conversation_id AND c.tenant_id=$1 AND c.deleted_at IS NULL
		LEFT JOIN digital_employees de ON de.id = c.digital_employee_id
		  AND de.tenant_id=$1 AND de.deleted_at IS NULL AND de.is_deleted=false
		WHERE m.tenant_id=$1 AND c.digital_employee_id IS NOT NULL
		  AND m.created_at >= now() - interval '7 days'
		GROUP BY c.digital_employee_id, de.name
		ORDER BY count(*) DESC
		LIMIT 5`, tenantID)
	if err != nil {
		return nil, err
	}
	defer topRows.Close()
	for topRows.Next() {
		var t TenantTopAgent
		if err := topRows.Scan(&t.Name, &t.Conversations7d, &t.Messages7d, &t.Users7d); err != nil {
			return nil, err
		}
		o.TopAgents = append(o.TopAgents, t)
	}
	if err := topRows.Err(); err != nil {
		return nil, err
	}
	return o, nil
}

func (s *impl) ListRuntimes(ctx context.Context) ([]Runtime, error) {
	// F02 v0.3: runtime_registrations + hosting_configs 合表入 runtime_environments;
	// code 列已删 (用 ''); adapter_kind 列已删 (常量 'external');
	// last_healthy_at 列移至 runtime_instances (取 MAX); endpoints 列已删, 给空 JSON。
	rows, err := s.pool.Query(ctx, `
		SELECT re.id, '' AS code, re.name, COALESCE(re.description, ''), COALESCE(re.framework, ''),
		       'external' AS adapter_kind, '{}'::jsonb AS endpoints,
		       COALESCE(re.data_egress,''), re.egress_audit_status,
		       re.status,
		       to_char((SELECT MAX(ri.last_healthy_at) FROM runtime_instances ri
		                 WHERE ri.runtime_environment_id = re.id AND ri.is_deleted = false),
		               'YYYY-MM-DD HH24:MI'),
		       (SELECT count(*) FROM runtime_instances ri
		         WHERE ri.runtime_environment_id = re.id AND ri.is_deleted = false),
		       (SELECT count(*) FROM digital_employees de
		         WHERE de.runtime_environment_id = re.id AND de.is_deleted = false)
		FROM runtime_environments re
		WHERE re.is_deleted = false
		ORDER BY re.id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Runtime{}
	for rows.Next() {
		var r Runtime
		var endpoints []byte
		var lastHealthy *string
		if err := rows.Scan(&r.ID, &r.Code, &r.Name, &r.Description, &r.Framework,
			&r.AdapterKind, &endpoints, &r.DataEgress, &r.EgressAuditStatus,
			&r.Status, &lastHealthy, &r.InstanceCount, &r.UsedByAgents); err != nil {
			return nil, err
		}
		if len(endpoints) > 0 {
			_ = json.Unmarshal(endpoints, &r.Endpoints)
		}
		if lastHealthy != nil {
			r.LastHealthyAt = *lastHealthy
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *impl) ListPlans(ctx context.Context) ([]Plan, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id, code, name, COALESCE(description, ''),
		       COALESCE(price_monthly, 0), currency, is_active, is_system
		FROM tenant_plans
		ORDER BY price_monthly NULLS FIRST, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Plan{}
	for rows.Next() {
		var p Plan
		if err := rows.Scan(&p.ID, &p.Code, &p.Name, &p.Description, &p.PriceMonthly, &p.Currency, &p.IsActive, &p.IsSystem); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *impl) RecentConversations(ctx context.Context, tenantID int64, limit int) ([]RecentConv, error) {
	if limit <= 0 || limit > 50 {
		limit = 10
	}
	rows, err := s.pool.Query(ctx, `
		SELECT c.uuid, COALESCE(c.title, '(新会话)'),
		       COALESCE(de.name, '-'), COALESCE(NULLIF(tm.nickname,''), a.display_name, ''),
		       to_char(COALESCE(c.last_message_at, c.created_at), 'YYYY-MM-DD HH24:MI'),
		       (SELECT count(*) FROM messages m WHERE m.conversation_id = c.id)
		FROM conversations c
		LEFT JOIN digital_employees de ON de.id = c.digital_employee_id
		LEFT JOIN accounts a ON a.id = c.account_id
		LEFT JOIN tenant_memberships tm ON tm.tenant_id = c.tenant_id
		     AND tm.account_id = c.account_id
		     AND tm.deleted_at IS NULL
		WHERE c.tenant_id = $1 AND c.deleted_at IS NULL
		ORDER BY COALESCE(c.last_message_at, c.created_at) DESC
		LIMIT $2`, tenantID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []RecentConv{}
	for rows.Next() {
		var r RecentConv
		if err := rows.Scan(&r.UUID, &r.Title, &r.AgentName, &r.AccountName, &r.LastAt, &r.MessageCount); err != nil {
			return nil, err
		}
		r.AccountName = cleanDashboardAccountName(r.AccountName)
		if r.AccountName == "" {
			r.AccountName = "未知用户"
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func cleanDashboardAccountName(name string) string {
	n := strings.TrimSpace(name)
	if n == "" || strings.Contains(n, "的组织 管理员") || strings.HasPrefix(n, "预热优化") {
		return ""
	}
	return n
}

// CapabilityCatalog 平台预置能力池, 给 Agent borrow 使用 (M3 §6.3)。
//
// kind:
//
//	composer_skill / background_skill / mcp  → is_system=true
//	knowledge_base                           → space_kind='platform' AND visibility='platform'
func (s *impl) CapabilityCatalog(ctx context.Context, tenantID int64, kind string) ([]CatalogItem, error) {
	out := []CatalogItem{}
	var q string
	switch kind {
	case "composer_skill":
		q = `SELECT 'composer_skill', uuid::text, COALESCE(code,''), label, '', '', ''
		     FROM composer_skills WHERE is_system=true AND deleted_at IS NULL ORDER BY id`
	case "background_skill":
		q = `SELECT 'background_skill', uuid::text, COALESCE(code,''), name, COALESCE(description,''), '', ''
		     FROM background_skills WHERE is_system=true AND deleted_at IS NULL ORDER BY id`
	case "mcp":
		q = `SELECT 'mcp', uuid::text, '', name, '', '', ''
		     FROM mcp_servers WHERE is_system=true AND deleted_at IS NULL ORDER BY id`
	case "knowledge_base":
		q = `SELECT 'knowledge_base', uuid::text, '', name, COALESCE(description,''), '', ''
		     FROM knowledge_bases WHERE space_kind='platform' AND visibility='platform' AND deleted_at IS NULL ORDER BY id`
	default:
		return nil, nil
	}
	rows, err := s.pool.Query(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var c CatalogItem
		if err := rows.Scan(&c.Kind, &c.UUID, &c.Code, &c.Name, &c.Description, &c.Vendor, &c.Category); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}
