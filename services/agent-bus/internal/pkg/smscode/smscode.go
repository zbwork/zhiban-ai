// Package smscode 提供手机短信验证码的发放、缓存与校验。
//
// Redis key 设计:
//
//	agbus:auth:smscode:{scene}:{mobile}     —— 当前有效验证码, TTL=300s
//	agbus:auth:smscode:cooldown:{mobile}    —— 发送冷却, TTL=60s
//	agbus:auth:smscode:attempt:{scene}:{mobile} —— 失败计数, TTL=600s
//
// 对外只暴露 Store + 简单的发送限流; 实际发短信由 sms.Sender 实现负责。
package smscode

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"time"

	redis "github.com/redis/go-redis/v9"
)

const (
	codeTTL        = 5 * time.Minute
	cooldownTTL    = 60 * time.Second
	attemptTTL     = 10 * time.Minute
	maxAttempts    = 5
	keyPfx         = "agbus:auth:smscode:"
	keyCooldownPfx = "agbus:auth:smscode:cooldown:"
	keyAttemptPfx  = "agbus:auth:smscode:attempt:"
	codeLen        = 6
)

// Scene 标识短信用途, 不同用途不共享验证码。
type Scene string

const (
	SceneLogin            Scene = "login"
	SceneRegister         Scene = "register"
	SceneMarketingContact Scene = "marketing_contact"
	// SceneMemberInviteJoin F28 H5 凭邀请 token 自助入企（与登录/营销验证码不互通）。
	SceneMemberInviteJoin Scene = "member_invite_join"
)

// 常见错误。
var (
	ErrCooldown = errors.New("smscode: cooldown not elapsed")
	ErrMismatch = errors.New("smscode: code mismatch or expired")
	ErrTooMany  = errors.New("smscode: too many failed attempts")
)

// Store 管理短信验证码生命周期。
type Store struct {
	rdb       *redis.Client
	fixedCode string // 非空时, Verify 对任意 mobile 接受该码 (仅本地/联调用)
}

// New 构造 store。
func New(rdb *redis.Client) *Store { return &Store{rdb: rdb} }

// SetFixedCode 设置本地"万能验证码", 仅用于本地/联调环境绕过短信触达。
// 传入空字符串表示禁用。生产环境必须保持禁用。
func (s *Store) SetFixedCode(code string) { s.fixedCode = code }

// FixedCode 返回当前万能码, 主要给日志/诊断用。
func (s *Store) FixedCode() string { return s.fixedCode }

// Issue 生成并写入 Redis,返回 6 位数字码。
// 同 mobile+scene 在 cooldownTTL 内重复发送时返回 ErrCooldown。
func (s *Store) Issue(ctx context.Context, scene Scene, mobile string) (string, error) {
	if mobile == "" {
		return "", fmt.Errorf("smscode: empty mobile")
	}
	cdKey := keyCooldownPfx + mobile
	ok, err := s.rdb.SetNX(ctx, cdKey, "1", cooldownTTL).Result()
	if err != nil {
		return "", err
	}
	if !ok {
		return "", ErrCooldown
	}
	code := randomDigits(codeLen)
	if err := s.rdb.Set(ctx, codeKey(scene, mobile), code, codeTTL).Err(); err != nil {
		return "", err
	}
	// 重置失败计数
	_ = s.rdb.Del(ctx, attemptKey(scene, mobile)).Err()
	return code, nil
}

// Verify 校验, 通过即删码。
// 多次失败 >= maxAttempts 时强行删除当前码并返回 ErrTooMany。
func (s *Store) Verify(ctx context.Context, scene Scene, mobile, code string) error {
	if mobile == "" || code == "" {
		return ErrMismatch
	}
	// 本地万能码: 命中即通过, 不消费 Redis 中真实码 (允许真实码继续可用)。
	if s.fixedCode != "" && code == s.fixedCode {
		return nil
	}
	k := codeKey(scene, mobile)
	stored, err := s.rdb.Get(ctx, k).Result()
	if err == redis.Nil {
		return ErrMismatch
	}
	if err != nil {
		return err
	}
	if stored != code {
		// 计数 +1
		ak := attemptKey(scene, mobile)
		n, _ := s.rdb.Incr(ctx, ak).Result()
		_, _ = s.rdb.Expire(ctx, ak, attemptTTL).Result()
		if n >= maxAttempts {
			_ = s.rdb.Del(ctx, k).Err()
			return ErrTooMany
		}
		return ErrMismatch
	}
	// 通过, 清理
	_ = s.rdb.Del(ctx, k).Err()
	_ = s.rdb.Del(ctx, attemptKey(scene, mobile)).Err()
	return nil
}

// Peek 仅看是否存在(给测试或诊断用), 不消费。
func (s *Store) Peek(ctx context.Context, scene Scene, mobile string) (string, error) {
	v, err := s.rdb.Get(ctx, codeKey(scene, mobile)).Result()
	if err == redis.Nil {
		return "", nil
	}
	return v, err
}

func codeKey(scene Scene, mobile string) string { return keyPfx + string(scene) + ":" + mobile }
func attemptKey(scene Scene, mobile string) string {
	return keyAttemptPfx + string(scene) + ":" + mobile
}

func randomDigits(n int) string {
	b := make([]byte, n)
	for i := range b {
		v, _ := rand.Int(rand.Reader, big.NewInt(10))
		b[i] = byte('0' + v.Int64())
	}
	return string(b)
}
