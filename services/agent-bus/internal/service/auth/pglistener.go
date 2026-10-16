package auth

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

// RevokeListener 监听 PostgreSQL NOTIFY 频道, 把撤销事件写到 Redis 黑名单。
//
// M1 §8: Admin 改 PG (UPDATE role_assignments.deleted_at) 后发 NOTIFY auth_revoke 'account:<id>'
// Bus 侧本协程负责接住通知 -> RedisRevoker.RevokeAccount; 这样 access token 撤销可在 ≤ 1s 生效。
//
// payload 约定:
//
//	"account:<aid>"            撤销该账号所有 token (按 issued_at <= now)
//	"session:<sid>"            撤销单个 session
//	"account:<aid>:session:<sid>" 同时撤销账号 + session
//
// 启动方式: go listener.Run(ctx)。Run 会一直阻塞直到 ctx 被取消。
type RevokeListener struct {
	pool   *pgxpool.Pool
	rev    *RedisRevoker
	logger *logpkg.Logger
}

// NewRevokeListener 构造。
func NewRevokeListener(pool *pgxpool.Pool, rev *RedisRevoker, logger *logpkg.Logger) *RevokeListener {
	return &RevokeListener{pool: pool, rev: rev, logger: logger}
}

// Run 阻塞监听 auth_revoke 频道。失败自动重连 (1s backoff)。
func (l *RevokeListener) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		if err := l.loop(ctx); err != nil {
			l.logger.Warn(ctx, "pglisten.auth_revoke.loop_err", "err", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Second):
			}
		}
	}
}

func (l *RevokeListener) loop(ctx context.Context) error {
	conn, err := l.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "LISTEN auth_revoke"); err != nil {
		return err
	}
	l.logger.Info(ctx, "pglisten.auth_revoke.listening")
	for {
		notif, err := conn.Conn().WaitForNotification(ctx)
		if err != nil {
			return err
		}
		l.handle(ctx, notif.Payload)
	}
}

// handle 解析 payload 并写 Redis 黑名单。
func (l *RevokeListener) handle(ctx context.Context, payload string) {
	parts := strings.Split(payload, ":")
	var aid int64
	var sid string
	for i := 0; i+1 < len(parts); i += 2 {
		switch parts[i] {
		case "account":
			if v, err := strconv.ParseInt(parts[i+1], 10, 64); err == nil {
				aid = v
			}
		case "session":
			sid = parts[i+1]
		}
	}
	if aid > 0 {
		_ = l.rev.RevokeAccount(ctx, aid, time.Now())
		l.logger.Info(ctx, "pglisten.auth_revoke.account", "aid", aid)
	}
	if sid != "" {
		_ = l.rev.RevokeSession(ctx, sid, 0)
		l.logger.Info(ctx, "pglisten.auth_revoke.session", "sid", sid)
	}
}
