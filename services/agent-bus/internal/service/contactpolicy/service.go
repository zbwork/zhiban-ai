// Package contactpolicy 提供租户级通讯录配置 (M2 §3.4 / §5.2)。
//
// 与 service/contacts 的关系: contacts 走客户端 (Bus) 读路径,
// 这里走 admin 写路径; 两者读到的字段定义保持一致, 故此包返回的 DTO
// 字段名/枚举与 contacts.ContactPolicy 对齐。
package contactpolicy

import (
	"context"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Policy 与 contacts.ContactPolicy 字段保持同名, JSON 也用 camelCase。
type Policy struct {
	TenantID                   int64  `json:"tenantId"`
	DefaultLanding             string `json:"defaultLanding"`
	DefaultShowPhone           string `json:"defaultShowPhone"`
	DefaultShowEmail           string `json:"defaultShowEmail"`
	DefaultShowTitle           string `json:"defaultShowTitle"`
	SearchScope                string `json:"searchScope"`
	WhoCanCreateGroupWithAgent string `json:"whoCanCreateGroupWithAgent"`
	AgentsDefaultInvitable     bool   `json:"agentsDefaultInvitable"`
	HumansDefaultInvitable     bool   `json:"humansDefaultInvitable"`
	ShowPlatformAgents         bool   `json:"showPlatformAgents"`
}

// UpdateInput 全字段覆盖 (admin 抽屉一次保存)。
type UpdateInput struct {
	DefaultLanding             *string `json:"defaultLanding,omitempty"`
	DefaultShowPhone           *string `json:"defaultShowPhone,omitempty"`
	DefaultShowEmail           *string `json:"defaultShowEmail,omitempty"`
	DefaultShowTitle           *string `json:"defaultShowTitle,omitempty"`
	SearchScope                *string `json:"searchScope,omitempty"`
	WhoCanCreateGroupWithAgent *string `json:"whoCanCreateGroupWithAgent,omitempty"`
	AgentsDefaultInvitable     *bool   `json:"agentsDefaultInvitable,omitempty"`
	HumansDefaultInvitable     *bool   `json:"humansDefaultInvitable,omitempty"`
	ShowPlatformAgents         *bool   `json:"showPlatformAgents,omitempty"`
}

// Service 接口 (admin 端)。
type Service interface {
	Get(ctx context.Context, tenantID int64) (*Policy, error)
	Update(ctx context.Context, tenantID int64, in UpdateInput) (*Policy, error)
}

type impl struct{ pool *pgxpool.Pool }

// New 构造默认实现。
func New(pool *pgxpool.Pool) Service { return &impl{pool: pool} }

func (s *impl) Get(ctx context.Context, tenantID int64) (*Policy, error) {
	if tenantID <= 0 {
		return nil, apperr.ErrForbidden.Withf("missing tenant")
	}
	row := s.pool.QueryRow(ctx, selectSQL, tenantID)
	p, err := scan(row)
	if err == pgx.ErrNoRows {
		// 兜底: 返回 schema 默认 (与 service/contacts 兜底保持一致)
		return defaultPolicy(tenantID), nil
	}
	return p, err
}

func (s *impl) Update(ctx context.Context, tenantID int64, in UpdateInput) (*Policy, error) {
	if tenantID <= 0 {
		return nil, apperr.ErrForbidden.Withf("missing tenant")
	}
	if err := validateInput(in); err != nil {
		return nil, err
	}

	// upsert 兼容首次配置
	_, err := s.pool.Exec(ctx, `
		INSERT INTO contact_policies (tenant_id) VALUES ($1)
		ON CONFLICT (tenant_id) DO NOTHING`, tenantID)
	if err != nil {
		return nil, err
	}

	// 用 COALESCE($n::type, col) 做"未传则保留"
	row := s.pool.QueryRow(ctx, `
		UPDATE contact_policies SET
			default_landing                   = COALESCE($1, default_landing),
			default_show_phone                = COALESCE($2, default_show_phone),
			default_show_email                = COALESCE($3, default_show_email),
			default_show_title                = COALESCE($4, default_show_title),
			search_scope                      = COALESCE($5, search_scope),
			who_can_create_group_with_agent   = COALESCE($6, who_can_create_group_with_agent),
			agents_default_invitable          = COALESCE($7, agents_default_invitable),
			humans_default_invitable          = COALESCE($8, humans_default_invitable),
			show_platform_agents              = COALESCE($9, show_platform_agents),
			updated_at                        = now()
		WHERE tenant_id = $10
		RETURNING tenant_id, default_landing,
			default_show_phone, default_show_email, default_show_title,
			search_scope, who_can_create_group_with_agent,
			agents_default_invitable, humans_default_invitable, show_platform_agents`,
		in.DefaultLanding, in.DefaultShowPhone, in.DefaultShowEmail, in.DefaultShowTitle,
		in.SearchScope, in.WhoCanCreateGroupWithAgent,
		in.AgentsDefaultInvitable, in.HumansDefaultInvitable, in.ShowPlatformAgents,
		tenantID)
	p, err := scan(row)
	if err != nil {
		return nil, err
	}
	// M2 §8: 通知 Bus 失效 policy 缓存 (≤ 1s 生效)
	if _, nerr := s.pool.Exec(ctx,
		`SELECT pg_notify('config_change', $1)`,
		"contact_policies:"+strconv.FormatInt(tenantID, 10)); nerr != nil {
		// notify 失败不阻断写, 只记日志 (caller 持有 logger 时可观测; 这里静默)
		_ = nerr
	}
	return p, nil
}

const selectSQL = `
	SELECT tenant_id, default_landing,
	       default_show_phone, default_show_email, default_show_title,
	       search_scope, who_can_create_group_with_agent,
	       agents_default_invitable, humans_default_invitable, show_platform_agents
	FROM contact_policies WHERE tenant_id=$1`

func scan(row pgx.Row) (*Policy, error) {
	var p Policy
	if err := row.Scan(&p.TenantID, &p.DefaultLanding,
		&p.DefaultShowPhone, &p.DefaultShowEmail, &p.DefaultShowTitle,
		&p.SearchScope, &p.WhoCanCreateGroupWithAgent,
		&p.AgentsDefaultInvitable, &p.HumansDefaultInvitable, &p.ShowPlatformAgents); err != nil {
		return nil, err
	}
	return &p, nil
}

func defaultPolicy(tenantID int64) *Policy {
	return &Policy{
		TenantID:                   tenantID,
		DefaultLanding:             "org_tree",
		DefaultShowPhone:           "department",
		DefaultShowEmail:           "department",
		DefaultShowTitle:           "all",
		SearchScope:                "tenant",
		WhoCanCreateGroupWithAgent: "any_member",
		AgentsDefaultInvitable:     false,
		HumansDefaultInvitable:     true,
		ShowPlatformAgents:         true,
	}
}

func validateInput(in UpdateInput) error {
	if v := in.DefaultLanding; v != nil && !contains(landingValues, *v) {
		return apperr.ErrInvalidParams.Withf("defaultLanding 非法: %s", *v)
	}
	if v := in.SearchScope; v != nil && !contains(scopeValues, *v) {
		return apperr.ErrInvalidParams.Withf("searchScope 非法: %s", *v)
	}
	if v := in.WhoCanCreateGroupWithAgent; v != nil && !contains(whoValues, *v) {
		return apperr.ErrInvalidParams.Withf("whoCanCreateGroupWithAgent 非法: %s", *v)
	}
	for name, v := range map[string]*string{
		"defaultShowPhone": in.DefaultShowPhone,
		"defaultShowEmail": in.DefaultShowEmail,
		"defaultShowTitle": in.DefaultShowTitle,
	} {
		if v != nil && !contains(fieldValues, *v) {
			return apperr.ErrInvalidParams.Withf("%s 非法: %s", name, *v)
		}
	}
	return nil
}

var (
	landingValues = []string{"org_tree", "agent_plaza"}
	scopeValues   = []string{"current_dept", "tenant", "tenant_plus_platform_agents"}
	whoValues     = []string{"tenant_admin", "any_member", "disabled"}
	fieldValues   = []string{"all", "department", "self", "hidden"}
)

func contains(list []string, v string) bool {
	v = strings.TrimSpace(v)
	for _, s := range list {
		if s == v {
			return true
		}
	}
	return false
}
