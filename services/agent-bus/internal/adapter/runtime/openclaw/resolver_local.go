package openclaw

import "context"

// LegacyLocalResolver 所有用户共用一个本地 OpenClaw 容器 (DEPRECATED, Batch 2C 起仅
// 供旧 HTTP+SSE adapter 使用; 新代码请用 LocalRegistryResolver, 按 runtime_registration_id 解析)。
type LegacyLocalResolver struct {
	URL    string
	Bearer string
}

// NewLegacyLocalResolver 构造 local 模式 resolver (DEPRECATED)。
//
// url 通常是 `AGBUS_RUNTIME_LOCAL_URL`，默认 `http://127.0.0.1:18789`。
// 与 ai-office 的 OPENCLAW_LOCAL_GATEWAY_URL 等价，但用全新变量。
func NewLegacyLocalResolver(url, bearer string) *LegacyLocalResolver {
	return &LegacyLocalResolver{URL: url, Bearer: bearer}
}

func (r *LegacyLocalResolver) Resolve(ctx context.Context, tenantID, accountID int64) (string, string, error) {
	if r.URL == "" {
		return "", "", &legacyResolverError{Msg: "local openclaw URL not configured (set AGBUS_RUNTIME_LOCAL_URL)"}
	}
	return r.URL, r.Bearer, nil
}

type legacyResolverError struct{ Msg string }

func (e *legacyResolverError) Error() string { return e.Msg }
