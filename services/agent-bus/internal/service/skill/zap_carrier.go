// zap_carrier.go — ZAP-1.1 §11.1 技能集装载：rail 过滤（与 /skill-rail-config 同规则）+ 包签名 URL + builtin_key。
//
// 调用方：chat ZAP 派发（POST /sessions body.skills）与绑定变化后的 live session resync（cmd/bus prewarm worker）。
// 协议过滤规则（§11.1）由 GetSkillRail 承担（tenant disable / status=active / 灰度版本 / kind 分流）；
// 这里只补 self_hosted 永远空集（boundaries §2.3）与包 URL 签名。
package skill

import (
	"context"
	"strings"
	"time"

	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// zapPackageURLTTL 下发给 runtime 的包签名 URL 有效期（§11.1 默认 1h；runtime 按 sha256 缓存，过期只影响首次下载）。
const zapPackageURLTTL = time.Hour

// BuildZapSessionSkills 构造 (tenant, account, agent) 视角的 ZAP skills 节。
//
//   - agent 不属于该租户 → ErrForbidden；self_hosted agent → 空集（不借用任何平台技能）。
//   - agent 技能没有可签名的包（包存储未配置 / 版本无包）→ 该技能跳过，不让整个会话开不了。
//   - 永不返回 nil carrier（调用方可直接序列化）。
func (s *Service) BuildZapSessionSkills(ctx context.Context, tenantID, accountID int64, agentUUID string) (*SkillsCarrier, error) {
	if s.agents == nil {
		return nil, apperr.ErrInternal.Withf("agent lookup not wired")
	}
	if tenantID <= 0 || accountID <= 0 || strings.TrimSpace(agentUUID) == "" {
		return nil, apperr.ErrInvalidParams.Withf("tenant_id / account_id / agent_uuid required")
	}
	ag, err := s.agents.GetAgentByUUID(ctx, agentUUID)
	if err != nil {
		return nil, err
	}
	if ag.TenantID != tenantID && ag.Source != "platform" {
		return nil, apperr.ErrForbidden.Withf("agent.cross_tenant")
	}
	empty := &SkillsCarrier{AgentSkills: []AgentSkillCarrier{}, BuiltinSkills: []BuiltinSkillCarrier{}}
	if strings.EqualFold(strings.TrimSpace(ag.IntegrationMode), "self_hosted") {
		return empty, nil
	}
	rail, err := s.GetSkillRail(ctx, domskill.GetSkillRailInput{AccountID: accountID, TenantID: tenantID, AgentUUID: agentUUID})
	if err != nil {
		return nil, err
	}
	items := append([]domskill.SkillRailItem{}, rail.ChipRail...)
	items = append(items, rail.MoreDrawer...)
	packages := map[string]packageMeta{}
	builtinKeys := map[string]string{}
	for _, it := range items {
		switch it.Kind {
		case domskill.KindAgent:
			if it.VersionUUID == "" {
				continue
			}
			if _, done := packages[it.VersionUUID]; done {
				continue
			}
			meta, ok := s.signSkillPackage(ctx, it.VersionUUID)
			if ok {
				packages[it.VersionUUID] = meta
			}
		case domskill.KindBuiltin:
			sk, err := s.repo.GetSkillByUUID(ctx, it.SkillUUID, false)
			if err == nil && sk != nil && sk.BuiltinKey != nil {
				builtinKeys[it.SkillUUID] = *sk.BuiltinKey
			}
		}
	}
	return BuildSessionCarrier(rail, packages, builtinKeys), nil
}

// signSkillPackage 取版本包元数据并签下载 URL。版本没包 / 包存储未配置 / 签名失败 → (zero, false)。
// 历史行 package_url 若已是绝对 http(s) URL 则直接使用。
func (s *Service) signSkillPackage(ctx context.Context, versionUUID string) (packageMeta, bool) {
	ver, err := s.repo.GetVersionByUUID(ctx, versionUUID)
	if err != nil || ver == nil || strings.TrimSpace(ver.PackageURL) == "" {
		return packageMeta{}, false
	}
	meta := packageMeta{SHA256: strings.ToLower(strings.TrimSpace(ver.PackageSHA256))}
	if ver.PackageSizeBytes != nil {
		meta.SizeBytes = *ver.PackageSizeBytes
	}
	key := strings.TrimSpace(ver.PackageURL)
	if strings.HasPrefix(strings.ToLower(key), "http://") || strings.HasPrefix(strings.ToLower(key), "https://") {
		meta.URL = key
		return meta, true
	}
	if s.packages == nil {
		return packageMeta{}, false
	}
	signed, _, err := s.packages.SignURL(ctx, key, zapPackageURLTTL)
	if err != nil || signed == "" {
		return packageMeta{}, false
	}
	meta.URL = signed
	return meta, true
}
