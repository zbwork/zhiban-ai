// Package agentsdk 实现 F01 §3.6 自定义 Agent SDK 接入 (场景 6) 业务逻辑。
//
// 公开能力 (Service 接口见 domain/agentsdk):
//   - IssueCredential / List / Patch / Revoke / ValidateClientCredentials  ↔ 长期凭证
//   - IssueSessionToken / ValidateSessionToken / RevokeSessionToken         ↔ 短期会话凭证
//
// 字符串格式:
//   - client_id  = "agentsdk_" + 32 base62
//   - client_sec = 48 base62 (一次性明文)
//   - session_token (raw, 不入库) = "st_<8 hex>_<32 base62>"
//
// hash 算法与 apikey 一致: sha256(明文) hex。
package agentsdk

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentsdk"
	domaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// MaxDerivationChainDepth F01 §3.6.3 派生链硬上限.
//
// F09 a2a depth ≤ 3 决议 (D6), 但 session 派生链可能比 a2a 边链路稍长 (master + 每跳 1 个 child).
// 取 10 给运维余裕, 同时防止 pathological loop (FK self-reference 是 DAG, 但极端攻击场景下还是兜底).
const MaxDerivationChainDepth = 10

// Deps 服务依赖。
type Deps struct {
	CredRepo      dom.CredentialRepo
	SessionRepo   dom.SessionTokenRepo
	RuntimeAccess dom.RuntimeAccessResolver
	Now           func() time.Time
	AsyncTouch    bool
	// TouchDebounce session_token / credential 命中后 last_used_at 写库间隔。
	// 0 = 默认 60s; 防 codex challenge #4 (每请求一个 goroutine + DB write 放大)。
	TouchDebounce time.Duration
	// Audit (可选; nil = skip) F01 §3.6.3 派生链 / chain revoke 审计.
	// 失败 fire-and-forget, 不阻塞主流程.
	Audit domaudit.Store
}

type Service struct {
	cred          dom.CredentialRepo
	st            dom.SessionTokenRepo
	runtimeAccess dom.RuntimeAccessResolver
	now           func() time.Time
	asyncTouch    bool
	debounce      time.Duration
	audit         domaudit.Store

	// touch 节流: id → 最近一次写库时间。两个 map 各管 credential / session_token。
	touchMu       sync.Mutex
	credTouchedAt map[int64]time.Time
	stTouchedAt   map[int64]time.Time
}

func New(d Deps) *Service {
	now := d.Now
	if now == nil {
		now = time.Now
	}
	deb := d.TouchDebounce
	if deb <= 0 {
		deb = 60 * time.Second
	}
	return &Service{
		cred: d.CredRepo, st: d.SessionRepo, runtimeAccess: d.RuntimeAccess, now: now, asyncTouch: d.AsyncTouch,
		debounce:      deb,
		audit:         d.Audit,
		credTouchedAt: map[int64]time.Time{},
		stTouchedAt:   map[int64]time.Time{},
	}
}

// shouldTouch 限流: 距上次写库未到 debounce 间隔则跳过。线程安全。
func (s *Service) shouldTouch(m map[int64]time.Time, id int64) bool {
	now := s.now()
	s.touchMu.Lock()
	defer s.touchMu.Unlock()
	if last, ok := m[id]; ok && now.Sub(last) < s.debounce {
		return false
	}
	m[id] = now
	return true
}

const (
	clientIDLabel = "agentsdk_"
	stPrefixLabel = "st_"

	clientIDRandBytes = 24 // base62 ~32 chars
	clientSecBytes    = 36 // base62 ~48 chars
	stPrefixBytes     = 4  // hex 8
	stSecretBytes     = 24 // base62 32
	maxRetries        = 5
)

// =====================================================
// Credential 侧
// =====================================================

func (s *Service) IssueCredential(ctx context.Context, tenantID, creatorID int64, name string, caps []string, runtimeRegID *int64) (*dom.Credential, string, error) {
	return s.issueCredential(ctx, dom.CredentialScopeTenant, tenantID, creatorID, name, caps, runtimeRegID)
}

func (s *Service) IssuePlatformCredential(ctx context.Context, creatorID int64, name string, caps []string, runtimeEnvironmentID int64, tenantGrantMode string, allowedTenantIDs []int64) (*dom.Credential, string, error) {
	if runtimeEnvironmentID <= 0 {
		return nil, "", apperr.ErrInvalidParams.Withf("runtime_environment_id required")
	}
	if tenantGrantMode == "" {
		tenantGrantMode = dom.PlatformTenantGrantAllowlist
	}
	if tenantGrantMode != dom.PlatformTenantGrantAllEnabled && tenantGrantMode != dom.PlatformTenantGrantAllowlist {
		return nil, "", apperr.ErrInvalidParams.Withf("tenant grant mode invalid")
	}
	if tenantGrantMode == dom.PlatformTenantGrantAllowlist && len(allowedTenantIDs) == 0 {
		return nil, "", apperr.ErrInvalidParams.Withf("allowed tenant ids required")
	}
	allowedTenantIDs = normalizeTenantIDs(allowedTenantIDs)
	if tenantGrantMode == dom.PlatformTenantGrantAllowlist && len(allowedTenantIDs) == 0 {
		return nil, "", apperr.ErrInvalidParams.Withf("allowed tenant ids required")
	}
	runtimeID := runtimeEnvironmentID
	row, secret, err := s.issueCredential(ctx, dom.CredentialScopePlatform, 0, creatorID, name, caps, &runtimeID)
	if err != nil {
		return nil, "", err
	}
	if err := s.cred.SetTenantGrants(ctx, row.ID, tenantGrantMode, allowedTenantIDs); err != nil {
		_ = s.cred.RevokePlatform(ctx, row.UUID)
		return nil, "", err
	}
	row.TenantGrantMode = tenantGrantMode
	row.AllowedTenantIDs = append([]int64(nil), allowedTenantIDs...)
	if tenantGrantMode == dom.PlatformTenantGrantAllEnabled {
		row.AllowedTenantIDs = nil
	}
	return row, secret, nil
}

func normalizeTenantIDs(in []int64) []int64 {
	if len(in) == 0 {
		return nil
	}
	seen := map[int64]struct{}{}
	out := make([]int64, 0, len(in))
	for _, id := range in {
		if id <= 0 {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, id)
	}
	return out
}

func (s *Service) issueCredential(ctx context.Context, scope string, tenantID, creatorID int64, name string, caps []string, runtimeRegID *int64) (*dom.Credential, string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil, "", apperr.ErrInvalidParams.Withf("name required")
	}
	if scope == "" {
		scope = dom.CredentialScopeTenant
	}
	if scope != dom.CredentialScopeTenant && scope != dom.CredentialScopePlatform {
		return nil, "", apperr.ErrInvalidParams.Withf("scope invalid")
	}
	if creatorID <= 0 {
		return nil, "", apperr.ErrInvalidParams.Withf("creator required")
	}
	if scope == dom.CredentialScopeTenant && tenantID <= 0 {
		return nil, "", apperr.ErrInvalidParams.Withf("tenant required")
	}
	if len(caps) == 0 {
		return nil, "", apperr.ErrInvalidParams.Withf("capability_bindings required")
	}
	for _, c := range caps {
		if !isValidCapability(c) {
			return nil, "", apperr.ErrInvalidParams.Withf("unknown capability %q", c)
		}
	}

	for i := 0; i < maxRetries; i++ {
		clientID, plaintextSec, err := genClientCredentials()
		if err != nil {
			return nil, "", apperr.ErrInternal.Wrap(err)
		}
		c := &dom.Credential{
			TenantID:             tenantID,
			CreatorID:            creatorID,
			Name:                 name,
			ClientID:             clientID,
			ClientSecretHash:     hashSecret(plaintextSec),
			CapabilityBindings:   caps,
			RuntimeEnvironmentID: runtimeRegID,
			Scope:                scope,
			Status:               "active",
		}
		if err := s.cred.Insert(ctx, c); err != nil {
			if isUniqueViolation(err) {
				continue
			}
			return nil, "", err
		}
		return c, plaintextSec, nil
	}
	return nil, "", apperr.ErrInternal.Withf("client_id collision after %d retries", maxRetries)
}

func (s *Service) ListCredentials(ctx context.Context, tenantID int64) ([]dom.Credential, error) {
	if tenantID <= 0 {
		return nil, apperr.ErrInvalidParams
	}
	return s.cred.ListByTenant(ctx, tenantID)
}

func (s *Service) ListPlatformCredentials(ctx context.Context) ([]dom.Credential, error) {
	return s.cred.ListPlatform(ctx)
}

func (s *Service) GetCredential(ctx context.Context, tenantID int64, uuid string) (*dom.Credential, error) {
	if tenantID <= 0 || uuid == "" {
		return nil, apperr.ErrInvalidParams
	}
	return s.cred.GetByUUID(ctx, tenantID, uuid)
}

func (s *Service) PatchCredential(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*dom.Credential, error) {
	if tenantID <= 0 || uuid == "" {
		return nil, apperr.ErrInvalidParams
	}
	clean := map[string]any{}
	if v, ok := fields["name"]; ok {
		ns, _ := v.(string)
		ns = strings.TrimSpace(ns)
		if ns == "" || len(ns) > 128 {
			return nil, apperr.ErrInvalidParams.Withf("name invalid")
		}
		clean["name"] = ns
	}
	if v, ok := fields["capability_bindings"]; ok {
		ss, ok2 := v.([]string)
		if !ok2 || len(ss) == 0 {
			return nil, apperr.ErrInvalidParams.Withf("capability_bindings required")
		}
		for _, x := range ss {
			if !isValidCapability(x) {
				return nil, apperr.ErrInvalidParams.Withf("unknown capability %q", x)
			}
		}
		clean["capability_bindings"] = ss
	}
	if v, ok := fields["runtime_environment_id"]; ok {
		clean["runtime_environment_id"] = v
	}
	return s.cred.Patch(ctx, tenantID, uuid, clean)
}

// RevokeCredential 撤销 credential, 并级联撤销其颁发的所有 active session_tokens
// (codex challenge #1: revoke credential 必须立刻杀掉已发的 token, 否则等于"撤销无效")。
func (s *Service) RevokeCredential(ctx context.Context, tenantID int64, uuid string) error {
	if tenantID <= 0 || uuid == "" {
		return apperr.ErrInvalidParams
	}
	c, err := s.cred.GetByUUID(ctx, tenantID, uuid)
	if err != nil {
		return err
	}
	if err := s.cred.Revoke(ctx, tenantID, uuid); err != nil {
		return err
	}
	if _, err := s.st.RevokeByCredential(ctx, c.ID); err != nil {
		// 不阻塞主流程: 即使 cascade revoke 失败, ValidateSessionToken 现在也会查
		// 父 credential.status, token 自动作废。这里只记日志即可 (无 logger 注入则忽略)。
		_ = err
	}
	return nil
}

func (s *Service) RevokePlatformCredential(ctx context.Context, uuid string) error {
	if uuid == "" {
		return apperr.ErrInvalidParams
	}
	c, err := s.cred.GetPlatformByUUID(ctx, uuid)
	if err != nil {
		return err
	}
	if err := s.cred.RevokePlatform(ctx, uuid); err != nil {
		return err
	}
	if _, err := s.st.RevokeByCredential(ctx, c.ID); err != nil {
		_ = err
	}
	return nil
}

func (s *Service) ValidateClientCredentials(ctx context.Context, clientID, clientSecret string) (*dom.Credential, error) {
	if clientID == "" || clientSecret == "" {
		return nil, apperr.ErrUnauthorized.Withf("invalid client credentials")
	}
	c, err := s.cred.FindByClientID(ctx, clientID)
	if err != nil {
		return nil, apperr.ErrUnauthorized.Withf("invalid client credentials")
	}
	if subtle.ConstantTimeCompare([]byte(c.ClientSecretHash), []byte(hashSecret(clientSecret))) != 1 {
		return nil, apperr.ErrUnauthorized.Withf("invalid client credentials")
	}
	if c.Status != "active" {
		return nil, apperr.ErrUnauthorized.Withf("invalid client credentials")
	}
	if s.shouldTouch(s.credTouchedAt, c.ID) {
		ts := s.now()
		if s.asyncTouch {
			go func(id int64, t time.Time) {
				bg, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer cancel()
				_ = s.cred.TouchLastUsed(bg, id, t)
			}(c.ID, ts)
		} else {
			_ = s.cred.TouchLastUsed(ctx, c.ID, ts)
		}
	}
	return c, nil
}

// =====================================================
// SessionToken 侧
// =====================================================

func (s *Service) IssueSessionToken(ctx context.Context, credentialID int64, conversationID, agentID *int64, caps []string, ttl time.Duration) (*dom.SessionToken, string, error) {
	if credentialID <= 0 {
		return nil, "", apperr.ErrInvalidParams
	}
	c, err := s.cred.GetByID(ctx, credentialID)
	if err != nil {
		return nil, "", err
	}
	if c.Status != "active" {
		return nil, "", apperr.ErrForbidden.Withf("credential not active")
	}
	if c.Scope == dom.CredentialScopePlatform {
		return nil, "", apperr.ErrForbidden.Withf("platform credential must use runtime_access grant")
	}
	if len(caps) == 0 {
		// 默认拷父凭证全集
		caps = append([]string(nil), c.CapabilityBindings...)
	} else if !dom.IsSubset(caps, c.CapabilityBindings) {
		return nil, "", apperr.ErrForbidden.Withf("requested capabilities exceed credential bindings")
	}
	// codex challenge #2: TTL 必须 server-side clamp; caller 给的最长 = MaxSessionTokenTTL。
	if ttl <= 0 || ttl > dom.MaxSessionTokenTTL {
		ttl = dom.DefaultSessionTokenTTL
	}
	for i := 0; i < maxRetries; i++ {
		prefix, secret, err := genSessionToken()
		if err != nil {
			return nil, "", apperr.ErrInternal.Wrap(err)
		}
		t := &dom.SessionToken{
			CredentialID:       c.ID,
			TenantID:           c.TenantID,
			ConversationID:     conversationID,
			AgentID:            agentID,
			TokenPrefix:        prefix,
			TokenHash:          hashSecret(secret),
			CapabilityBindings: caps,
			ExpiresAt:          s.now().Add(ttl),
			Status:             "active",
		}
		if err := s.st.Insert(ctx, t); err != nil {
			if isUniqueViolation(err) {
				continue
			}
			return nil, "", err
		}
		plaintext := stPrefixLabel + prefix + "_" + secret
		return t, plaintext, nil
	}
	return nil, "", apperr.ErrInternal.Withf("session token prefix collision after %d retries", maxRetries)
}

func (s *Service) IssueRuntimeAccessToken(ctx context.Context, credentialID int64, req dom.RuntimeAccessRequest) (*dom.SessionToken, string, error) {
	if credentialID <= 0 {
		return nil, "", apperr.ErrInvalidParams
	}
	if s.runtimeAccess == nil {
		return nil, "", apperr.ErrInternal.Withf("runtime access resolver not wired")
	}
	c, err := s.cred.GetByID(ctx, credentialID)
	if err != nil {
		return nil, "", err
	}
	if c.Status != "active" {
		return nil, "", apperr.ErrForbidden.Withf("credential not active")
	}
	if c.Scope == "" {
		c.Scope = dom.CredentialScopeTenant
	}
	if c.Scope != dom.CredentialScopeTenant && c.Scope != dom.CredentialScopePlatform {
		return nil, "", apperr.ErrForbidden.Withf("credential scope not allowed")
	}
	caps := append([]string(nil), c.CapabilityBindings...)
	resolved, err := s.runtimeAccess.ResolveRuntimeAccess(ctx, c, req)
	if err != nil {
		return nil, "", err
	}
	if resolved == nil || resolved.TenantID <= 0 || resolved.RuntimeEnvironmentID <= 0 {
		return nil, "", apperr.ErrForbidden.Withf("runtime access binding incomplete")
	}
	ttl := req.TTL
	if ttl <= 0 || ttl > dom.MaxSessionTokenTTL {
		ttl = dom.DefaultSessionTokenTTL
	}
	runtimeID := resolved.RuntimeEnvironmentID
	accountID := req.AccountID
	if accountID == nil && resolved.AccountID != nil {
		accountID = resolved.AccountID
	}
	for i := 0; i < maxRetries; i++ {
		prefix, secret, gerr := genSessionToken()
		if gerr != nil {
			return nil, "", apperr.ErrInternal.Wrap(gerr)
		}
		t := &dom.SessionToken{
			CredentialID:   c.ID,
			TenantID:       resolved.TenantID,
			AccountID:      accountID,
			ConversationID: req.ConversationID,
			// AgentID (A2A v1a): 仅换发请求带 agent_uuid 且 resolver 三项校验通过时非 nil,
			// 供 /zap/v1/internal/a2a/invoke 识别 from_agent。缺省 nil = 旧行为。
			AgentID:              resolved.AgentID,
			RuntimeEnvironmentID: &runtimeID,
			TokenPrefix:          prefix,
			TokenHash:            hashSecret(secret),
			CapabilityBindings:   caps,
			ExpiresAt:            s.now().Add(ttl),
			Status:               "active",
		}
		if ierr := s.st.Insert(ctx, t); ierr != nil {
			if isUniqueViolation(ierr) {
				continue
			}
			return nil, "", ierr
		}
		plaintext := stPrefixLabel + prefix + "_" + secret
		s.fireAuditRuntimeTokenIssue(ctx, c, t, req, caps, ttl)
		return t, plaintext, nil
	}
	return nil, "", apperr.ErrInternal.Withf("session token prefix collision after %d retries", maxRetries)
}

// ResolveRuntimeAccessAgent 在业务请求期校验动态 agent_id 是否落在当前 st_ 的
// tenant/runtime 边界内。
func (s *Service) ResolveRuntimeAccessAgent(ctx context.Context, agentUUID string, tenantID, runtimeEnvironmentID int64) (int64, error) {
	if s.runtimeAccess == nil {
		return 0, apperr.ErrInternal.Withf("runtime access resolver not wired")
	}
	if strings.TrimSpace(agentUUID) == "" {
		return 0, apperr.ErrInvalidParams.Withf("agent_id required")
	}
	if tenantID <= 0 || runtimeEnvironmentID <= 0 {
		return 0, apperr.ErrForbidden.Withf("runtime access token required")
	}
	return s.runtimeAccess.ResolveRuntimeAccessAgent(ctx, strings.TrimSpace(agentUUID), tenantID, runtimeEnvironmentID)
}

func (s *Service) ValidateSessionToken(ctx context.Context, raw string) (*dom.Identity, error) {
	prefix, secret, ok := parseSessionToken(raw)
	if !ok {
		return nil, apperr.ErrUnauthorized.Withf("invalid session token")
	}
	row, err := s.st.FindByPrefix(ctx, prefix)
	if err != nil {
		return nil, apperr.ErrUnauthorized.Withf("invalid session token")
	}
	if subtle.ConstantTimeCompare([]byte(row.TokenHash), []byte(hashSecret(secret))) != 1 {
		return nil, apperr.ErrUnauthorized.Withf("invalid session token")
	}
	if row.Status != "active" {
		return nil, apperr.ErrUnauthorized.Withf("invalid session token")
	}
	if !row.ExpiresAt.After(s.now()) {
		return nil, apperr.ErrUnauthorized.Withf("invalid session token")
	}
	// codex challenge #1: 必须级联查父 credential 状态;
	// revoke credential 后即使本 row.status 还是 active, 也要拒绝。
	cred, err := s.cred.GetByID(ctx, row.CredentialID)
	if err != nil || cred.Status != "active" {
		return nil, apperr.ErrUnauthorized.Withf("invalid session token")
	}
	// F01 §3.6.3 (F09 PR4.5): 沿 parent_session_id 链回溯任一 ancestor 不活跃/过期 → 拒.
	// row 自己已校验过 (status='active' + expires_at > now), 这里只走 ancestor.
	cur := row
	for i := 0; i < MaxDerivationChainDepth && cur.ParentSessionID != nil; i++ {
		parent, perr := s.st.GetByID(ctx, *cur.ParentSessionID)
		if perr != nil {
			return nil, apperr.ErrUnauthorized.Withf("invalid session token")
		}
		if parent.Status != "active" || !parent.ExpiresAt.After(s.now()) {
			return nil, apperr.ErrUnauthorized.Withf("invalid session token")
		}
		cur = parent
	}
	if cur.ParentSessionID != nil {
		// 超过 MaxDerivationChainDepth 仍未到 master → 链路深得反常, 安全策略拒绝.
		return nil, apperr.ErrUnauthorized.Withf("invalid session token")
	}

	id := &dom.Identity{
		SessionTokenID:     row.ID,
		CredentialID:       row.CredentialID,
		TenantID:           row.TenantID,
		CapabilityBindings: append([]string(nil), row.CapabilityBindings...),
	}
	if row.AccountID != nil {
		id.AccountID = *row.AccountID
	}
	if row.ConversationID != nil {
		id.ConversationID = *row.ConversationID
	}
	if row.AgentID != nil {
		id.AgentID = *row.AgentID
	}
	if row.RuntimeEnvironmentID != nil {
		id.RuntimeEnvironmentID = *row.RuntimeEnvironmentID
	}
	// codex challenge #4: TouchLastUsed 走 debounce (60s 间隔), 防热路径 goroutine + DB 放大。
	if s.shouldTouch(s.stTouchedAt, row.ID) {
		ts := s.now()
		if s.asyncTouch {
			go func(rid int64, t time.Time) {
				bg, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer cancel()
				_ = s.st.TouchLastUsed(bg, rid, t)
			}(row.ID, ts)
		} else {
			_ = s.st.TouchLastUsed(ctx, row.ID, ts)
		}
	}
	return id, nil
}

// IssueDerivedSessionToken F01 §3.6.3 / F09 PR4.5 派生子 session.
//
// 由 F09 A2A invoke handler 在 step 9 调用:
//
//	"签发新 session_token (subject_agent_uuid=B, parent_session=A.session)"
//
// 规则见 domain/agentsdk Service.IssueDerivedSessionToken 注释.
func (s *Service) IssueDerivedSessionToken(
	ctx context.Context,
	parentSessionTokenID int64,
	targetAgentID int64,
	caps []string,
	ttl time.Duration,
) (*dom.SessionToken, string, error) {
	if parentSessionTokenID <= 0 {
		return nil, "", apperr.ErrInvalidParams.Withf("parent_session_token_id required")
	}
	if targetAgentID <= 0 {
		return nil, "", apperr.ErrInvalidParams.Withf("target_agent_id required")
	}

	parent, err := s.st.GetByID(ctx, parentSessionTokenID)
	if err != nil {
		return nil, "", apperr.ErrUnauthorized.Withf("invalid parent session")
	}
	if parent.Status != "active" {
		return nil, "", apperr.ErrUnauthorized.Withf("parent session not active")
	}
	now := s.now()
	if !parent.ExpiresAt.After(now) {
		return nil, "", apperr.ErrUnauthorized.Withf("parent session expired")
	}

	// 链路完整性: ancestor 也必须全部 active. 复用 Validate 风格的链路走法.
	cur := parent
	for i := 0; i < MaxDerivationChainDepth && cur.ParentSessionID != nil; i++ {
		ancestor, gerr := s.st.GetByID(ctx, *cur.ParentSessionID)
		if gerr != nil {
			return nil, "", apperr.ErrUnauthorized.Withf("invalid parent chain")
		}
		if ancestor.Status != "active" || !ancestor.ExpiresAt.After(now) {
			return nil, "", apperr.ErrUnauthorized.Withf("ancestor session not active")
		}
		cur = ancestor
	}
	if cur.ParentSessionID != nil {
		return nil, "", apperr.ErrForbidden.Withf("derivation chain too deep (>%d)", MaxDerivationChainDepth)
	}

	// 顶层 credential 必须 active.
	cred, err := s.cred.GetByID(ctx, parent.CredentialID)
	if err != nil || cred.Status != "active" {
		return nil, "", apperr.ErrUnauthorized.Withf("root credential not active")
	}

	// caps 收窄: child caps ⊆ parent caps. 空 caps = 继承 parent 全集.
	if len(caps) == 0 {
		caps = append([]string(nil), parent.CapabilityBindings...)
	} else if !dom.IsSubset(caps, parent.CapabilityBindings) {
		return nil, "", apperr.ErrForbidden.Withf("requested capabilities exceed parent session bindings")
	}

	// TTL clamp 三重: 全局上限 + caller 请求 + parent 剩余寿命.
	if ttl <= 0 || ttl > dom.MaxSessionTokenTTL {
		ttl = dom.DefaultSessionTokenTTL
	}
	parentRemaining := parent.ExpiresAt.Sub(now)
	if ttl > parentRemaining {
		ttl = parentRemaining
	}
	if ttl <= 0 {
		return nil, "", apperr.ErrUnauthorized.Withf("parent session expiring")
	}

	targetAgentPtr := targetAgentID
	for i := 0; i < maxRetries; i++ {
		prefix, secret, gerr := genSessionToken()
		if gerr != nil {
			return nil, "", apperr.ErrInternal.Wrap(gerr)
		}
		parentIDCopy := parent.ID
		t := &dom.SessionToken{
			CredentialID:         parent.CredentialID,
			TenantID:             parent.TenantID,
			AccountID:            parent.AccountID,
			ConversationID:       parent.ConversationID, // 继承
			AgentID:              &targetAgentPtr,       // 子 session 代表新 agent
			RuntimeEnvironmentID: parent.RuntimeEnvironmentID,
			ParentSessionID:      &parentIDCopy,
			TokenPrefix:          prefix,
			TokenHash:            hashSecret(secret),
			CapabilityBindings:   caps,
			ExpiresAt:            now.Add(ttl),
			Status:               "active",
		}
		if ierr := s.st.Insert(ctx, t); ierr != nil {
			if isUniqueViolation(ierr) {
				continue
			}
			return nil, "", ierr
		}
		plaintext := stPrefixLabel + prefix + "_" + secret
		s.fireAuditDerive(ctx, parent, t, caps, ttl)
		return t, plaintext, nil
	}
	return nil, "", apperr.ErrInternal.Withf("session token prefix collision after %d retries", maxRetries)
}

// CleanupExpiredSessionTokens 后台 cron 调; 删过期 + 撤销 7+ 天前的 session_tokens 行。
func (s *Service) CleanupExpiredSessionTokens(ctx context.Context) (int64, error) {
	return s.st.CleanupExpired(ctx)
}

// RevokeSessionToken 主动撤销.
//
// F01 §3.6.3 (F09 PR4.5): 撤销时一并 cascade revoke 该 session 派生的所有 descendant chain.
// 一条 master session 撤销 → 由它派生的所有 a2a child session 同步撤销. 防"撤了父但子还能用".
func (s *Service) RevokeSessionToken(ctx context.Context, uuid string) error {
	if uuid == "" {
		return apperr.ErrInvalidParams
	}
	n, err := s.st.RevokeChainByUUID(ctx, uuid)
	if err != nil {
		return err
	}
	s.fireAuditRevokeChain(ctx, uuid, n)
	return nil
}

// fireAuditDerive 写一条 audit_events: domain=agentsdk, kind=session_token.derive.
// 失败 fire-and-forget; 不阻塞业务.
func (s *Service) fireAuditDerive(ctx context.Context, parent, child *dom.SessionToken, caps []string, ttl time.Duration) {
	if s.audit == nil {
		return
	}
	payload := map[string]any{
		"parent_session_uuid": parent.UUID,
		"child_session_uuid":  child.UUID,
		"child_caps":          caps,
		"ttl_seconds":         int64(ttl / time.Second),
	}
	if parent.AgentID != nil {
		payload["parent_agent_id"] = *parent.AgentID
	}
	if child.AgentID != nil {
		payload["child_agent_id"] = *child.AgentID
	}
	if conv := child.ConversationID; conv != nil {
		payload["conversation_id"] = *conv
	}
	raw, _ := json.Marshal(payload)
	ev := domaudit.Event{
		OccurredAt:   s.now(),
		TenantID:     parent.TenantID,
		ActorKind:    domaudit.ActorAgent,
		Domain:       "agentsdk",
		EventKind:    "session_token.derive",
		Severity:     domaudit.SeverityInfo,
		ResourceKind: "session_token",
		ResourceUUID: child.UUID,
		Payload:      raw,
	}
	_ = s.audit.Insert(ctx, ev)
}

// fireAuditRuntimeTokenIssue writes the high-value platform runtime exchange event.
// Failures are best-effort and must not block token exchange.
func (s *Service) fireAuditRuntimeTokenIssue(ctx context.Context, cred *dom.Credential, tok *dom.SessionToken, req dom.RuntimeAccessRequest, caps []string, ttl time.Duration) {
	if s.audit == nil || tok == nil || cred == nil {
		return
	}
	payload := map[string]any{
		"credential_id":       tok.CredentialID,
		"credential_scope":    cred.Scope,
		"session_token_uuid":  tok.UUID,
		"tenant_id":           tok.TenantID,
		"capability_bindings": caps,
		"ttl_seconds":         int64(ttl / time.Second),
	}
	payload["tenant_id_param"] = req.TenantID
	if req.AgentUUID != "" {
		payload["agent_uuid_param"] = req.AgentUUID
	}
	if tok.AccountID != nil {
		payload["account_id"] = *tok.AccountID
	}
	if tok.AgentID != nil {
		payload["agent_id"] = *tok.AgentID
	}
	if tok.RuntimeEnvironmentID != nil {
		payload["runtime_environment_id"] = *tok.RuntimeEnvironmentID
	}
	raw, _ := json.Marshal(payload)
	ev := domaudit.Event{
		OccurredAt:   s.now(),
		TenantID:     tok.TenantID,
		AccountID:    ptrValue(tok.AccountID),
		ActorKind:    domaudit.ActorAgent,
		Domain:       "runtime",
		EventKind:    "runtime.token.issue",
		Severity:     domaudit.SeverityInfo,
		ResourceKind: "session_token",
		ResourceUUID: tok.UUID,
		Payload:      raw,
	}
	_ = s.audit.Insert(ctx, ev)
}

// fireAuditRevokeChain 写 audit_events: domain=agentsdk, kind=session_token.revoke_chain.
func (s *Service) fireAuditRevokeChain(ctx context.Context, rootUUID string, affected int64) {
	if s.audit == nil {
		return
	}
	raw, _ := json.Marshal(map[string]any{
		"root_uuid":      rootUUID,
		"rows_revoked":   affected,
		"includes_chain": true,
	})
	ev := domaudit.Event{
		OccurredAt:   s.now(),
		ActorKind:    domaudit.ActorSystem,
		Domain:       "agentsdk",
		EventKind:    "session_token.revoke_chain",
		Severity:     domaudit.SeverityInfo,
		ResourceKind: "session_token",
		ResourceUUID: rootUUID,
		Payload:      raw,
	}
	_ = s.audit.Insert(ctx, ev)
}

// =====================================================
// 内部 helpers
// =====================================================

// isValidCapability 与 domain/apikey.IsValidScope 同款; 这里独立维护以解耦。
func isValidCapability(c string) bool {
	switch c {
	case "kb.read", "zhiban.kb.search", "drive.read", "memory.read", "memory.write", "notification.write", "chat.message.write", "chat.file.read", "org.read", "a2a.invoke":
		return true
	case "platform.tenant.provision": // 平台级:代 OPC 自注册企业开通租户
		return true
	case "memory.recall", "memory:*":
		return true
	}
	return false
}

func ptrValue(v *int64) int64 {
	if v == nil {
		return 0
	}
	return *v
}

func parseSessionToken(raw string) (prefix, secret string, ok bool) {
	if !strings.HasPrefix(raw, stPrefixLabel) {
		return "", "", false
	}
	rest := raw[len(stPrefixLabel):]
	i := strings.Index(rest, "_")
	if i <= 0 || i == len(rest)-1 {
		return "", "", false
	}
	return rest[:i], rest[i+1:], true
}

func genClientCredentials() (string, string, error) {
	var idBuf [clientIDRandBytes]byte
	if _, err := rand.Read(idBuf[:]); err != nil {
		return "", "", err
	}
	var secBuf [clientSecBytes]byte
	if _, err := rand.Read(secBuf[:]); err != nil {
		return "", "", err
	}
	return clientIDLabel + base62Encode(idBuf[:], 32), base62Encode(secBuf[:], 48), nil
}

func genSessionToken() (string, string, error) {
	var pb [stPrefixBytes]byte
	if _, err := rand.Read(pb[:]); err != nil {
		return "", "", err
	}
	var sb [stSecretBytes]byte
	if _, err := rand.Read(sb[:]); err != nil {
		return "", "", err
	}
	return hex.EncodeToString(pb[:]), base62Encode(sb[:], 32), nil
}

func hashSecret(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

const b62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

func base62Encode(in []byte, outLen int) string {
	work := append([]byte(nil), in...)
	result := make([]byte, outLen)
	for i := outLen - 1; i >= 0; i-- {
		var rem int
		for j := 0; j < len(work); j++ {
			cur := rem*256 + int(work[j])
			work[j] = byte(cur / 62)
			rem = cur % 62
		}
		result[i] = b62[rem]
	}
	return string(result)
}

func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "23505") || strings.Contains(msg, "duplicate key value")
}

// EnsurePlatformCredentialWithSecret 用**部署方给定**的 client_id/secret 幂等保证一条平台级凭据存在
// (平台自营 dsh 运行时自动登记, ADR-0035 修订: 凭据对由部署密钥同时注入 Bus 与 runtime, 不走一次性弹窗下发)。
//
//   - 不存在 → 按给定 id + sha256(secret) 插入, 绑 runtime_environment_id, tenant_grant=all_enabled;
//   - 已存在且 hash 一致 → 按需补齐 capability_bindings / runtime_environment_id (只增不减), 返回;
//   - 已存在但 hash 不一致 → 返回 ErrConflict (secret 轮换必须先吊销旧凭据, 不静默覆盖)。
//
// secret 明文只参与 hash 计算, 不入日志、不回显。
func (s *Service) EnsurePlatformCredentialWithSecret(ctx context.Context, creatorID int64, name, clientID, clientSecret string, caps []string, runtimeEnvironmentID int64) (*dom.Credential, error) {
	name = strings.TrimSpace(name)
	clientID = strings.TrimSpace(clientID)
	if name == "" || clientID == "" || strings.TrimSpace(clientSecret) == "" {
		return nil, apperr.ErrInvalidParams.Withf("name, client_id and client_secret required")
	}
	if runtimeEnvironmentID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("runtime_environment_id required")
	}
	if creatorID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("creator account required (agent_sdk_credentials.creator_id is NOT NULL)")
	}
	if len(caps) == 0 {
		return nil, apperr.ErrInvalidParams.Withf("capability_bindings required")
	}
	for _, c := range caps {
		if !isValidCapability(c) {
			return nil, apperr.ErrInvalidParams.Withf("unknown capability %q", c)
		}
	}
	wantHash := hashSecret(clientSecret)
	existing, err := s.cred.FindByClientID(ctx, clientID)
	if err != nil && !errors.Is(err, apperr.ErrNotFound) {
		return nil, err
	}
	if existing != nil {
		if subtle.ConstantTimeCompare([]byte(existing.ClientSecretHash), []byte(wantHash)) != 1 {
			return nil, apperr.ErrConflict.Withf("platform credential %s exists with a different secret; revoke it before rotating", clientID)
		}
		if existing.Status != "active" {
			return nil, apperr.ErrConflict.Withf("platform credential %s is %s", clientID, existing.Status)
		}
		fields := map[string]any{}
		if merged, changed := mergeCapabilities(existing.CapabilityBindings, caps); changed {
			fields["capability_bindings"] = merged
		}
		if existing.RuntimeEnvironmentID == nil || *existing.RuntimeEnvironmentID != runtimeEnvironmentID {
			fields["runtime_environment_id"] = runtimeEnvironmentID
		}
		if len(fields) > 0 {
			if _, err := s.cred.Patch(ctx, 0, existing.UUID, fields); err != nil {
				return nil, err
			}
		}
		if existing.TenantGrantMode != dom.PlatformTenantGrantAllEnabled {
			if err := s.cred.SetTenantGrants(ctx, existing.ID, dom.PlatformTenantGrantAllEnabled, nil); err != nil {
				return nil, err
			}
		}
		return s.cred.FindByClientID(ctx, clientID)
	}
	envID := runtimeEnvironmentID
	c := &dom.Credential{
		TenantID:             0,
		CreatorID:            creatorID,
		Name:                 name,
		ClientID:             clientID,
		ClientSecretHash:     wantHash,
		CapabilityBindings:   append([]string(nil), caps...),
		RuntimeEnvironmentID: &envID,
		Scope:                dom.CredentialScopePlatform,
		Status:               "active",
	}
	if err := s.cred.Insert(ctx, c); err != nil {
		return nil, err
	}
	if err := s.cred.SetTenantGrants(ctx, c.ID, dom.PlatformTenantGrantAllEnabled, nil); err != nil {
		return nil, err
	}
	return c, nil
}

// mergeCapabilities 只增不减地合并能力集; changed=false 表示无新增。
func mergeCapabilities(existing, want []string) ([]string, bool) {
	seen := map[string]bool{}
	out := make([]string, 0, len(existing)+len(want))
	for _, c := range existing {
		if c = strings.TrimSpace(c); c != "" && !seen[c] {
			seen[c] = true
			out = append(out, c)
		}
	}
	changed := false
	for _, c := range want {
		if c = strings.TrimSpace(c); c != "" && !seen[c] {
			seen[c] = true
			out = append(out, c)
			changed = true
		}
	}
	return out, changed
}
