package resolver

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

// Listener · 监听 PG NOTIFY config_change channel; 收到 payload `kb_provider_config:<id>`
// 即 Invalidate 对应 provider 缓存; 收到 `kb_provider_config:*` 或解析不出 id → InvalidateAll.
//
// 与 boundaries §6.1 一致 (复用 config_change channel; 不开独立 channel).
type Listener struct {
	pool     *pgxpool.Pool
	resolver *Resolver
	logger   *log.Logger
}

func NewListener(pool *pgxpool.Pool, r *Resolver, logger *log.Logger) *Listener {
	return &Listener{pool: pool, resolver: r, logger: logger}
}

// Run blocks until ctx cancel; LISTEN config_change + 反查关键字 invalidate.
//
// Best-effort: PG 不可达时退避重连. 不会阻塞主流程 (cmd/bus 用单独 goroutine).
func (l *Listener) Run(ctx context.Context) {
	for {
		if err := l.runOnce(ctx); err != nil {
			if ctx.Err() != nil {
				return
			}
			if l.logger != nil {
				l.logger.Warn(ctx, "kbprovider listener disconnected; reconnecting in 2s", "err", err)
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(2 * time.Second):
			}
			continue
		}
		return
	}
}

func (l *Listener) runOnce(ctx context.Context) error {
	conn, err := l.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "LISTEN config_change"); err != nil {
		return err
	}
	for {
		n, err := conn.Conn().WaitForNotification(ctx)
		if err != nil {
			return err
		}
		if n == nil {
			continue
		}
		payload := n.Payload
		// 仅处理 kb_provider_config:<id> 前缀; 其它 channel payload (composer_skills/emp_block_registry 等) 跳过.
		const prefix = "kb_provider_config:"
		if !strings.HasPrefix(payload, prefix) {
			continue
		}
		idStr := strings.TrimPrefix(payload, prefix)
		idStr = strings.TrimSpace(idStr)
		if idStr == "" || idStr == "*" {
			l.resolver.InvalidateAll()
			if l.logger != nil {
				l.logger.Info(ctx, "kbprovider cache invalidate all", "payload", payload)
			}
			continue
		}
		id, err := strconv.ParseInt(idStr, 10, 64)
		if err != nil {
			// payload 不解析就保守 InvalidateAll.
			l.resolver.InvalidateAll()
			continue
		}
		l.resolver.Invalidate(id)
		if l.logger != nil {
			l.logger.Info(ctx, "kbprovider cache invalidate", "provider_id", id)
		}
	}
}
