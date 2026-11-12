// Package apikey 实现 F01 §3.5 API Key 业务逻辑 (Issue / List / Revoke / Validate)。
//
// 一次性明文格式 ek_<prefix>_<secret>:
//   - prefix: 8 字符 hex (uq_api_keys_prefix 索引保证唯一; 撞了重试 5 次)
//   - secret: 32 字符 base62
//
// 数据库只存 prefix 明文 + sha256(secret) hex; 明文 secret 仅在 Issue 时返回, 此后不可恢复。
package apikey

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"strings"
	"sync"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/apikey"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Deps 服务依赖。
type Deps struct {
	Repo dom.Repository
	// Now 注入便于测试; nil 时用 time.Now。
	Now func() time.Time
	// AsyncTouch 控制 Validate 命中后 TouchLastUsed 走异步; 测试可关掉。
	AsyncTouch bool
	// TouchDebounce 命中后 last_used_at 写库间隔; 0 = 60s。
	// 防 codex challenge #4 (每请求一个 goroutine + DB write 放大)。
	TouchDebounce time.Duration
}

// Service 是 dom.Service 实现。
type Service struct {
	repo       dom.Repository
	now        func() time.Time
	asyncTouch bool
	debounce   time.Duration

	touchMu      sync.Mutex
	keyTouchedAt map[int64]time.Time
}

// New 构造 Service。
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
		repo: d.Repo, now: now, asyncTouch: d.AsyncTouch,
		debounce:     deb,
		keyTouchedAt: map[int64]time.Time{},
	}
}

func (s *Service) shouldTouch(id int64) bool {
	now := s.now()
	s.touchMu.Lock()
	defer s.touchMu.Unlock()
	if last, ok := s.keyTouchedAt[id]; ok && now.Sub(last) < s.debounce {
		return false
	}
	s.keyTouchedAt[id] = now
	return true
}

const (
	keyPrefixLabel = "ek_"
	prefixBytes    = 4  // → 8 hex
	secretBytes    = 24 // → 32 base62 (恰好凑齐 length, 见 base62Encode)
	maxRetries     = 5
)

// Issue 见接口注释。
//
// 校验:
//   - name 必填、≤128
//   - scopes 非空 且每项在白名单
//   - expiresAt 若非 nil 必须 > now
func (s *Service) Issue(ctx context.Context, tenantID, creatorID int64, name string, scopes []string, expiresAt *time.Time) (*dom.ApiKey, string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil, "", apperr.ErrInvalidParams.Withf("name required")
	}
	if len(name) > 128 {
		return nil, "", apperr.ErrInvalidParams.Withf("name too long")
	}
	if tenantID <= 0 || creatorID <= 0 {
		return nil, "", apperr.ErrInvalidParams.Withf("tenantID/creatorID required")
	}
	if len(scopes) == 0 {
		return nil, "", apperr.ErrInvalidParams.Withf("scopes required")
	}
	for _, s := range scopes {
		if !dom.IsValidScope(s) {
			return nil, "", apperr.ErrInvalidParams.Withf("unknown scope %q", s)
		}
	}
	if expiresAt != nil && !expiresAt.After(s.now()) {
		return nil, "", apperr.ErrInvalidParams.Withf("expires_at must be in future")
	}

	for i := 0; i < maxRetries; i++ {
		prefix, secret, err := genKey()
		if err != nil {
			return nil, "", apperr.ErrInternal.Wrap(err)
		}
		k := &dom.ApiKey{
			TenantID:  tenantID,
			CreatorID: creatorID,
			Name:      name,
			KeyPrefix: prefix,
			KeyHash:   hashSecret(secret),
			Scopes:    scopes,
			ExpiresAt: expiresAt,
			Status:    "active",
		}
		if err := s.repo.Insert(ctx, k); err != nil {
			if isUniqueViolation(err) {
				continue // 撞 prefix, 重试
			}
			return nil, "", err
		}
		plaintext := keyPrefixLabel + prefix + "_" + secret
		return k, plaintext, nil
	}
	return nil, "", apperr.ErrInternal.Withf("prefix collision after %d retries", maxRetries)
}

// List 见接口注释。
func (s *Service) List(ctx context.Context, tenantID int64, filter dom.ListFilter) ([]dom.ApiKey, int64, error) {
	if tenantID <= 0 {
		return nil, 0, apperr.ErrInvalidParams.Withf("tenantID required")
	}
	filter.Status = strings.TrimSpace(filter.Status)
	switch filter.Status {
	case "", "active", "revoked", "expired":
	default:
		return nil, 0, apperr.ErrInvalidParams.Withf("status invalid")
	}
	filter.Keyword = strings.TrimSpace(filter.Keyword)
	if filter.Limit <= 0 {
		filter.Limit = 20
	}
	if filter.Limit > 100 {
		filter.Limit = 100
	}
	if filter.Offset < 0 {
		filter.Offset = 0
	}
	return s.repo.ListByTenant(ctx, tenantID, filter)
}

// Get 见接口注释。
func (s *Service) Get(ctx context.Context, tenantID int64, uuid string) (*dom.ApiKey, error) {
	if tenantID <= 0 || uuid == "" {
		return nil, apperr.ErrInvalidParams
	}
	return s.repo.GetByUUID(ctx, tenantID, uuid)
}

// Patch 见接口注释; 只允许改 name / scopes / expires_at。
func (s *Service) Patch(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*dom.ApiKey, error) {
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
	if v, ok := fields["scopes"]; ok {
		ss, ok2 := v.([]string)
		if !ok2 || len(ss) == 0 {
			return nil, apperr.ErrInvalidParams.Withf("scopes required")
		}
		for _, x := range ss {
			if !dom.IsValidScope(x) {
				return nil, apperr.ErrInvalidParams.Withf("unknown scope %q", x)
			}
		}
		clean["scopes"] = ss
	}
	if v, ok := fields["expires_at"]; ok {
		// nil = 取消过期; *time.Time = 设新过期
		if v == nil {
			clean["expires_at"] = nil
		} else {
			ts, ok2 := v.(*time.Time)
			if !ok2 || ts == nil {
				return nil, apperr.ErrInvalidParams.Withf("expires_at type")
			}
			if !ts.After(s.now()) {
				return nil, apperr.ErrInvalidParams.Withf("expires_at must be in future")
			}
			clean["expires_at"] = ts
		}
	}
	return s.repo.Patch(ctx, tenantID, uuid, clean)
}

// Revoke 见接口注释。
func (s *Service) Revoke(ctx context.Context, tenantID int64, uuid string) error {
	if tenantID <= 0 || uuid == "" {
		return apperr.ErrInvalidParams
	}
	return s.repo.Revoke(ctx, tenantID, uuid)
}

// Validate 见接口注释。
//
// 错误统一回 ErrUnauthorized; 不区分 prefix 不存在 vs secret 错 vs 过期 vs 撤销
// (防探测; 调用方拿到 401 后看 message 也只会看到统一的 "invalid api key")。
//
// 成功时若 asyncTouch=true 则起 goroutine TouchLastUsed (不阻塞主链路);
// 否则同步调 (单测便于断言)。
func (s *Service) Validate(ctx context.Context, raw string) (*dom.Identity, error) {
	prefix, secret, ok := parseKey(raw)
	if !ok {
		return nil, apperr.ErrUnauthorized.Withf("invalid api key")
	}
	row, err := s.repo.FindByPrefix(ctx, prefix)
	if err != nil {
		// 包括 NotFound; 一律 401。
		return nil, apperr.ErrUnauthorized.Withf("invalid api key")
	}
	if subtle.ConstantTimeCompare([]byte(row.KeyHash), []byte(hashSecret(secret))) != 1 {
		return nil, apperr.ErrUnauthorized.Withf("invalid api key")
	}
	if row.Status != "active" {
		return nil, apperr.ErrUnauthorized.Withf("invalid api key")
	}
	if row.ExpiresAt != nil && !row.ExpiresAt.After(s.now()) {
		return nil, apperr.ErrUnauthorized.Withf("invalid api key")
	}
	id := &dom.Identity{
		APIKeyID:  row.ID,
		TenantID:  row.TenantID,
		CreatorID: row.CreatorID,
		Scopes:    append([]string(nil), row.Scopes...),
	}
	// codex challenge #4: TouchLastUsed 走 debounce (60s 间隔), 防热路径 goroutine + DB 放大。
	if s.shouldTouch(row.ID) {
		ts := s.now()
		if s.asyncTouch {
			// 异步; 不传 ctx (避免主链路取消导致 last_used_at 永远没更新)。
			go func(rid int64, t time.Time) {
				bg, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer cancel()
				_ = s.repo.TouchLastUsed(bg, rid, t)
			}(row.ID, ts)
		} else {
			_ = s.repo.TouchLastUsed(ctx, row.ID, ts)
		}
	}
	return id, nil
}

// parseKey 解析 ek_<prefix>_<secret>; 严格匹配前缀 ek_ 和分隔符。
//
// 不做长度校验 (前缀长度可能未来调整); 只要 prefix 段非空 + secret 段非空即返。
// 真正鉴权靠后续的 prefix 查 + hash 比对。
func parseKey(raw string) (prefix, secret string, ok bool) {
	if !strings.HasPrefix(raw, keyPrefixLabel) {
		return "", "", false
	}
	rest := raw[len(keyPrefixLabel):]
	i := strings.Index(rest, "_")
	if i <= 0 || i == len(rest)-1 {
		return "", "", false
	}
	return rest[:i], rest[i+1:], true
}

// genKey 生成 (prefix, secret); prefix=8 hex, secret=32 base62。
func genKey() (string, string, error) {
	var pb [prefixBytes]byte
	if _, err := rand.Read(pb[:]); err != nil {
		return "", "", err
	}
	var sb [secretBytes]byte
	if _, err := rand.Read(sb[:]); err != nil {
		return "", "", err
	}
	return hex.EncodeToString(pb[:]), base62Encode(sb[:]), nil
}

// hashSecret 写库前对 secret 做 sha256, 输出 hex 字符串 (64 字符)。
func hashSecret(secret string) string {
	h := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(h[:])
}

const base62Alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

// base62Encode 朴素位移; 输入 24 字节, 输出 32 字符 (取 64-bit 块每 5-bit 编一字符)。
//
// 实现: 把字节流当作大端整数, 反复 div 62 取模; 不足 32 字符前补 '0'。
func base62Encode(in []byte) string {
	// 用大整数运算: 把 in 视为大端 base256, 反复对 62 取模, 收到 32 位字符。
	const out = 32
	work := append([]byte(nil), in...)
	result := make([]byte, out)
	for i := out - 1; i >= 0; i-- {
		var rem int
		for j := 0; j < len(work); j++ {
			cur := rem*256 + int(work[j])
			work[j] = byte(cur / 62)
			rem = cur % 62
		}
		result[i] = base62Alphabet[rem]
		// 不裁掉前导 0; 24 字节 ≈ 192-bit, 远小于 62^32, 输出固定长度。
	}
	return string(result)
}

// isUniqueViolation 检测 pg 唯一索引冲突 (uq_api_keys_prefix)。
//
// 不直接 import pgconn 以避免 service 层耦合 driver; 用字符串匹配 fallback。
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "23505") || strings.Contains(msg, "duplicate key value")
}
