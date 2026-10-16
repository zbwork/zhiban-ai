// identity_resolver.go — Plan 16 Phase 2:
// chat 服务层显式 tenant/account UUID 解析器。
//
// 设计纪律 (ai-office/CLAUDE.md hard rule):
// Service 方法不允许从 ctx.Value 取身份。本接口由 cmd/bus 在装配期注入,
// chat 服务在 ZAP 路径上把 (tenantID, accountID) 显式解成 UUID, 再透到
// runtime CreateSessionRequest.user — 不暴露内部数字主键给 runtime。
//
// 接口语义 (fail-closed):
//   - 任一 UUID 解失败 → 返回 ErrInvalidParams (上层包成 protocol_unsupported)
//   - 不缓存; 单聊 Send 每条都做一次 (热点表 acct/tenant; 100 µs 级别可接受)
//   - tenant/account 必须 active (status 字段不在本接口判定, 由 visibility 层兜底)
//
// 单测可 mock IdentityResolver, 不需要拉真实 tenant/account 表。

package chat

import (
	"context"
	"strings"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// IdentityResolver 把内部数字主键 (tenantID, accountID) 解析为 UUID。
//
// chat ZAP 路径用它构造 SessionUser{TenantUUID, AccountUUID} 透传给 runtime;
// runtime 用 UUID 做业务侧关联 (隔离 / 审计 / 反向回调), 不接收数字主键。
type IdentityResolver interface {
	ResolveTenantAccount(ctx context.Context, tenantID, accountID int64) (tenantUUID, accountUUID string, err error)
}

// IdentityProfileResolver 解析 ZAP identity provisioning 需要的最小账号画像。
//
// 兼容口径: 老测试/老装配只实现 IdentityResolver 也能跑; ZAP identity provisioning
// 开启后若需要 email/phone 等字段, service 会优先使用本接口。
type IdentityProfileResolver interface {
	ResolveTenantAccountProfile(ctx context.Context, tenantID, accountID int64) (*IdentityProfile, error)
}

// IdentityProfile 是 ZAP 自定义 Agent 会话前同步/解析用户时使用的平台身份快照。
// 只包含外部系统可复用的稳定标识与用户可见资料, 不暴露内部数字主键。
type IdentityProfile struct {
	TenantUUID   string
	TenantName   string
	AccountUUID  string
	DisplayName  string
	Email        string
	Phone        string
	Username     string
	ProviderUIDs map[string]string
}

// TenantUUIDLookup chat 服务对 tenant 仓库的窄接口 (避免 import 整个 domain/tenant)。
type TenantUUIDLookup interface {
	GetByIDUUID(ctx context.Context, id int64) (string, error)
}

// TenantProfileLookup 可选扩展: 取租户 UUID + 名称。
type TenantProfileLookup interface {
	GetByIDProfile(ctx context.Context, id int64) (uuid, name string, err error)
}

// AccountUUIDLookup chat 服务对 account 仓库的窄接口。
type AccountUUIDLookup interface {
	GetByIDUUID(ctx context.Context, id int64) (string, error)
}

// AccountProfileLookup 可选扩展: 取账号 UUID + 外部系统可用资料。
type AccountProfileLookup interface {
	GetByIDProfile(ctx context.Context, id int64) (uuid, displayName, email, phone, username string, providerUIDs map[string]string, err error)
}

// DefaultIdentityResolver 由两个窄 Lookup 适配 — 实际实现见 cmd/bus 的
// tenantRepoUUIDAdapter / accountRepoUUIDAdapter (用 domain/tenant.Repository
// + domain/account.Repository 的 GetByID 取 UUID 字段)。
type DefaultIdentityResolver struct {
	Tenants  TenantUUIDLookup
	Accounts AccountUUIDLookup
}

// ResolveTenantAccount fail-closed: 任一 UUID 为空 → ErrInvalidParams。
func (r *DefaultIdentityResolver) ResolveTenantAccount(ctx context.Context, tenantID, accountID int64) (string, string, error) {
	p, err := r.ResolveTenantAccountProfile(ctx, tenantID, accountID)
	if err != nil {
		return "", "", err
	}
	return p.TenantUUID, p.AccountUUID, nil
}

// ResolveTenantAccountProfile fail-closed: 任一 UUID 为空 → ErrInvalidParams。
func (r *DefaultIdentityResolver) ResolveTenantAccountProfile(ctx context.Context, tenantID, accountID int64) (*IdentityProfile, error) {
	if r == nil || r.Tenants == nil || r.Accounts == nil {
		return nil, apperr.ErrInternal.Withf("chat identity resolver not wired")
	}
	if tenantID <= 0 || accountID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("chat identity: tenant/account id required")
	}

	var tenantUUID, tenantName string
	if lookup, ok := r.Tenants.(TenantProfileLookup); ok {
		u, name, err := lookup.GetByIDProfile(ctx, tenantID)
		if err != nil {
			return nil, err
		}
		tenantUUID, tenantName = u, name
	} else {
		u, err := r.Tenants.GetByIDUUID(ctx, tenantID)
		if err != nil {
			return nil, err
		}
		tenantUUID = u
	}
	if strings.TrimSpace(tenantUUID) == "" {
		return nil, apperr.ErrInvalidParams.Withf("chat identity: tenant uuid empty for id=%d", tenantID)
	}

	var accountUUID, displayName, email, phone, username string
	var providerUIDs map[string]string
	if lookup, ok := r.Accounts.(AccountProfileLookup); ok {
		u, dn, mail, ph, un, pids, err := lookup.GetByIDProfile(ctx, accountID)
		if err != nil {
			return nil, err
		}
		accountUUID, displayName, email, phone, username = u, dn, mail, ph, un
		providerUIDs = pids
	} else {
		u, err := r.Accounts.GetByIDUUID(ctx, accountID)
		if err != nil {
			return nil, err
		}
		accountUUID = u
	}
	if strings.TrimSpace(accountUUID) == "" {
		return nil, apperr.ErrInvalidParams.Withf("chat identity: account uuid empty for id=%d", accountID)
	}
	return &IdentityProfile{
		TenantUUID:   strings.TrimSpace(tenantUUID),
		TenantName:   strings.TrimSpace(tenantName),
		AccountUUID:  strings.TrimSpace(accountUUID),
		DisplayName:  strings.TrimSpace(displayName),
		Email:        strings.TrimSpace(email),
		Phone:        strings.TrimSpace(phone),
		Username:     strings.TrimSpace(username),
		ProviderUIDs: providerUIDs,
	}, nil
}

// SetIdentityResolver chat 服务装配 setter。cmd/bus 注入 DefaultIdentityResolver。
func (s *impl) SetIdentityResolver(r IdentityResolver) { s.identityResolver = r }

// SetIdentityResolverOnService 公开 helper (与 SetAttachmentBinderOnService 同模式)。
func SetIdentityResolverOnService(svc Service, r IdentityResolver) {
	if im, ok := svc.(*impl); ok {
		im.SetIdentityResolver(r)
	}
}
