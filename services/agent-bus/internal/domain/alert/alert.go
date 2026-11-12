// Package alert 定义 F25 告警中心的 domain 契约。
//
// 设计权威 docs/features/F25-alert-center-and-admin-visibility.md §2-§3：
//   - 写主体 = cmd/worker 评估器（创建/累加/自动恢复）+ Admin（acknowledge / 人工 resolve）
//   - 状态机 firing → acknowledged → resolved（resolved 终态；已 ack 再命中只累加不回退）
//   - fingerprint 在未恢复态内唯一（partial unique），同异常去重累加
package alert

import (
	"context"
	"time"
)

// 状态机取值（与 alerts.status CHECK 一致）。
const (
	StatusFiring       = "firing"
	StatusAcknowledged = "acknowledged"
	StatusResolved     = "resolved"
)

// 严重度（与 alerts.severity CHECK 一致；不设 info——告警只针对需要行动的问题）。
const (
	SeverityWarning  = "warning"
	SeverityCritical = "critical"
)

// 责任范围（与 alerts.scope_kind CHECK 一致）。
const (
	ScopePlatform = "platform"
	ScopeTenant   = "tenant"
)

// Alert 是 alerts 表的一行。
type Alert struct {
	ID               int64
	UUID             string
	ScopeKind        string
	TenantID         *int64
	TenantName       string // 平台列表 JOIN tenants 填充；租户侧为空
	SourceKind       string
	AlertType        string
	Severity         string
	Status           string
	Fingerprint      string
	Title            string
	Summary          string
	ResourceKind     string
	ResourceUUID     string
	FirstTriggeredAt time.Time
	LastTriggeredAt  time.Time
	OccurrenceCount  int
	AcknowledgedBy   *int64
	AcknowledgedAt   *time.Time
	ResolvedAt       *time.Time
	ResolvedBy       *int64 // NULL=评估器自动恢复
	Context          map[string]any
	CreatedAt        time.Time
	UpdatedAt        time.Time
}

// TenantOpsAlertTypes 「租户经营类」告警：行动方是租户管理员（升级套餐/充值/清理资源），
// 平台无需逐条处置。平台侧的待处理视图（铃铛/总览/默认列表）默认排除这三类，
// 平台列表可显式带 IncludeTenantOps 查看；租户侧始终完整可见。（2026-07-12 产品拍板）
var TenantOpsAlertTypes = []string{"quota_threshold", "credit_low", "subscription_expiring"}

// ListFilter 列表筛选。TenantOnly 非 nil 时强制 scope_kind='tenant' AND tenant_id=*TenantOnly（租户侧隔离）；
// nil 时为平台侧查询，可用 TenantID 做可选筛选。
type ListFilter struct {
	TenantOnly *int64
	TenantID   *int64
	// IncludeTenantOps 仅平台侧生效：true 时不排除租户经营类告警（TenantOpsAlertTypes）。
	IncludeTenantOps bool
	Status           string
	Severity         string
	SourceKind       string
	AlertType        string
	From             *time.Time
	To               *time.Time
	Limit            int
	Offset           int
}

// Candidate 是评估器单轮对某条规则/某个资源的命中结果。
type Candidate struct {
	ScopeKind    string
	TenantID     *int64
	SourceKind   string
	AlertType    string
	Severity     string
	ResourceKey  string // fingerprint 资源维度；fingerprint = AlertType + "|" + ResourceKey
	Title        string
	Summary      string
	ResourceKind string
	ResourceUUID string
	Context      map[string]any
}

// Fingerprint 计算去重指纹。
func (c Candidate) Fingerprint() string { return c.AlertType + "|" + c.ResourceKey }

// Store 是告警仓储接口（admin 读写 + 评估器写）。
type Store interface {
	List(ctx context.Context, f ListFilter) ([]Alert, int64, error)
	GetByUUID(ctx context.Context, uuid string, tenantOnly *int64) (*Alert, error)
	CountFiring(ctx context.Context, tenantOnly *int64) (int64, error)
	// Acknowledge firing→acknowledged；已 ack/已恢复返回 domain 层可识别错误。
	Acknowledge(ctx context.Context, uuid string, tenantOnly *int64, by int64) (*Alert, error)
	// ResolveManual →resolved（resolved_by=by）；同 tx 发 notify.alert.resolved outbox。
	ResolveManual(ctx context.Context, uuid string, tenantOnly *int64, by int64) (*Alert, error)

	// ---- 评估器专用 ----
	// UpsertFiring 命中即建/累加：无未恢复行则 INSERT firing（同 tx 发 notify.alert.fired），
	// 有则 occurrence_count+1、last_triggered_at=now()。返回是否新建。
	UpsertFiring(ctx context.Context, c Candidate) (created bool, err error)
	// AutoResolve 按 fingerprint 自动恢复（resolved_by NULL；同 tx 发 notify.alert.resolved）。返回是否有行被恢复。
	AutoResolve(ctx context.Context, fingerprint string) (bool, error)
	// BumpRuleState 更新连击状态并返回更新后的连续命中数。
	BumpRuleState(ctx context.Context, ruleKey, resourceKey string, hit bool) (consecutiveHits, consecutiveMisses int, err error)
	// ListRuleStateResources 返回某规则当前有连击记录的 resource_key 集合（供本轮 miss 判定）。
	ListRuleStateResources(ctx context.Context, ruleKey string) ([]string, error)
	// ClearRuleState 恢复后清理连击行。
	ClearRuleState(ctx context.Context, ruleKey, resourceKey string) error
}
