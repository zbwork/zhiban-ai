package auth

import (
	"context"
	"strconv"
	"time"

	redis "github.com/redis/go-redis/v9"
)

// RedisRevoker 用 Redis 实现的撤销黑名单。
//
// key 设计:
//
//	agbus:auth:revoke:session:<sid>         => "1", TTL = access_ttl*2
//	agbus:auth:revoke:account:<aid>:not_before => RFC3339 时间戳 (issued_at <= 此时间则视为撤销), TTL=access_ttl*2
type RedisRevoker struct {
	rdb       *redis.Client
	accessTTL time.Duration
}

// NewRedisRevoker 构造。
func NewRedisRevoker(rdb *redis.Client, accessTTL time.Duration) *RedisRevoker {
	if accessTTL <= 0 {
		accessTTL = 15 * time.Minute
	}
	return &RedisRevoker{rdb: rdb, accessTTL: accessTTL}
}

// RevokeSession 单个 session 撤销。
func (r *RedisRevoker) RevokeSession(ctx context.Context, sessionUUID string, ttl time.Duration) error {
	if ttl <= 0 {
		ttl = r.accessTTL * 2
	}
	return r.rdb.Set(ctx, sessionKey(sessionUUID), "1", ttl).Err()
}

// RevokeAccount 撤销一个账号在某时间前签发的所有 token。
//
// 精度对齐 (Batch 2B closeout #1)：
// JWT iat 只精确到秒（UNIX 秒）。本处 until 来自 time.Now() 通常含纳秒。
// 之前的实现把 cutoff 用 RFC3339Nano 存进 Redis，导致同秒签发的旧 token 与新 token 都比 cutoff 小，
// 误判为已撤销 → 401。
//
// 修复：cutoff 以 UNIX 秒整数存 Redis；判定时 issuedAt.Unix() <= cutoff.Unix() 即视为撤销。
// 同秒规则：调用 RevokeAccount 时 until.Unix()=N → 任意 iat<=N 的 token（含同一秒的旧 token）都被撤销；
// 新登录后签的 token 的 iat=now()，必落在 N+1 或更后（除非时钟倒退）→ 不受影响。
func (r *RedisRevoker) RevokeAccount(ctx context.Context, accountID int64, until time.Time) error {
	cutoffSec := until.UTC().Unix()
	return r.rdb.Set(ctx, accountKey(accountID), strconv.FormatInt(cutoffSec, 10), r.accessTTL*2).Err()
}

// IsSessionRevoked 判 session 是否在黑名单。
func (r *RedisRevoker) IsSessionRevoked(ctx context.Context, sessionUUID string) (bool, error) {
	if sessionUUID == "" {
		return false, nil
	}
	v, err := r.rdb.Exists(ctx, sessionKey(sessionUUID)).Result()
	if err != nil {
		return false, err
	}
	return v > 0, nil
}

// ClearAccountRevoke 清掉账号级 revoke 标记。
//
// 用于：登录 / 改密成功后清掉旧 cutoff，让新签的 token 不被误判（issuedAt > cutoff 本应放行，
// 但若 cutoff 是几秒前的现在时刻，可能在 RFC3339Nano 精度上产生边界 race）。
func (r *RedisRevoker) ClearAccountRevoke(ctx context.Context, accountID int64) error {
	return r.rdb.Del(ctx, accountKey(accountID)).Err()
}

// IsAccountRevoked 判账号是否被撤销 (token issued_at <= cutoff)。
//
// 精度（Batch 2B closeout #1）：cutoff 与 issuedAt 都按秒比较；新调用方仍存 UNIX seconds 整数，
// 同时为向后兼容能读旧版 RFC3339Nano 字符串（落地到 .Unix() 比较）。
func (r *RedisRevoker) IsAccountRevoked(ctx context.Context, accountID int64, issuedAt time.Time) (bool, error) {
	if accountID == 0 || issuedAt.IsZero() {
		return false, nil
	}
	v, err := r.rdb.Get(ctx, accountKey(accountID)).Result()
	if err == redis.Nil {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var cutoffSec int64
	if n, perr := strconv.ParseInt(v, 10, 64); perr == nil {
		cutoffSec = n
	} else if t, perr := time.Parse(time.RFC3339Nano, v); perr == nil {
		cutoffSec = t.UTC().Unix()
	} else {
		// 无法解析（不应发生）→ 安全侧让 token 通过
		return false, nil
	}
	return issuedAt.UTC().Unix() <= cutoffSec, nil
}

func sessionKey(sid string) string { return "agbus:auth:revoke:session:" + sid }
func accountKey(aid int64) string  { return "agbus:auth:revoke:account:" + strconv.FormatInt(aid, 10) }

// ===== 失败锁定 (M1 §9: 5 次失败锁 15 分钟) =====
//
// Redis key 设计:
//   agbus:auth:fail:<aid>   计数, TTL 15min
//   agbus:auth:lock:<aid>   存在即锁定, TTL 15min

const (
	failTTL = 15 * time.Minute
	lockTTL = 15 * time.Minute
)

// BumpFailedLogin 失败计数 +1, 达到阈值则同时写锁。返回 (当前计数, 是否触发锁定)。
func (r *RedisRevoker) BumpFailedLogin(ctx context.Context, accountID int64, threshold int) (int64, bool, error) {
	if accountID == 0 {
		return 0, false, nil
	}
	n, err := r.rdb.Incr(ctx, failKey(accountID)).Result()
	if err != nil {
		return 0, false, err
	}
	if n == 1 {
		_, _ = r.rdb.Expire(ctx, failKey(accountID), failTTL).Result()
	}
	if int(n) >= threshold {
		_ = r.rdb.Set(ctx, lockKey(accountID), "1", lockTTL).Err()
		return n, true, nil
	}
	return n, false, nil
}

// ResetFailedLogin 登录成功后清计数。
func (r *RedisRevoker) ResetFailedLogin(ctx context.Context, accountID int64) error {
	if accountID == 0 {
		return nil
	}
	return r.rdb.Del(ctx, failKey(accountID), lockKey(accountID)).Err()
}

// IsLocked 判断账号是否处于锁定状态; 返回 (锁定, 剩余 TTL)。
func (r *RedisRevoker) IsLocked(ctx context.Context, accountID int64) (bool, time.Duration, error) {
	if accountID == 0 {
		return false, 0, nil
	}
	ttl, err := r.rdb.TTL(ctx, lockKey(accountID)).Result()
	if err != nil {
		return false, 0, err
	}
	if ttl > 0 {
		return true, ttl, nil
	}
	return false, 0, nil
}

func failKey(aid int64) string { return "agbus:auth:fail:" + strconv.FormatInt(aid, 10) }
func lockKey(aid int64) string { return "agbus:auth:lock:" + strconv.FormatInt(aid, 10) }
