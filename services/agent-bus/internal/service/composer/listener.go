// listener.go — composer service 监听 PG NOTIFY config_change, 失效 composer-config 本地缓存 (M6 §4.5).
//
// 复用 `config_change` 通道 (与 contacts.PolicyListener / empblock.Listener 同源).
// payload 形如:
//
//	composer_skills:<id>             → InvalidateAll (skill 影响多 agent)
//	apps:<id>                        → InvalidateAll
//	agent_capability_bindings:<de_id> → InvalidateAgentCache(deID)
//	digital_employees:<id>            → InvalidateAgentCache(deID)  // M6 reset-defaults / M3 publish 同款 payload
//	tenant_composer_defaults:<tenant_id> / tenant_app_defaults:<tenant_id> → InvalidateAll
//
// 其它 payload 直接忽略 (留给同 channel 的其它 listener 处理).
package composer

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

// Listener 阻塞监听 config_change, 失效 composer service 本地缓存.
type Listener struct {
	pool    *pgxpool.Pool
	service Service
	logger  *log.Logger
}

// NewListener 构造 listener; svc 必须非空.
func NewListener(pool *pgxpool.Pool, svc Service, logger *log.Logger) *Listener {
	if logger == nil {
		logger = log.Default()
	}
	return &Listener{pool: pool, service: svc, logger: logger}
}

// Run 阻塞监听 config_change. ctx 取消时退出.
// 推荐 cmd/bus 在自己的 bgWG 里跑.
func (l *Listener) Run(ctx context.Context) {
	for {
		if err := l.runOnce(ctx); err != nil {
			if ctx.Err() != nil {
				return
			}
			l.logger.Warn(ctx, "composer listener: loop err; retry in 1s", "err", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(1 * time.Second):
			}
		}
	}
}

func (l *Listener) runOnce(ctx context.Context) error {
	conn, err := l.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "LISTEN "+ConfigChangeChannel); err != nil {
		return err
	}
	l.logger.Info(ctx, "composer listener: listening "+ConfigChangeChannel)
	for {
		notif, err := conn.Conn().WaitForNotification(ctx)
		if err != nil {
			return err
		}
		l.handle(ctx, notif.Payload)
	}
}

func (l *Listener) handle(ctx context.Context, payload string) {
	prefix, idStr, ok := strings.Cut(payload, ":")
	if !ok {
		return
	}
	switch prefix {
	case "composer_skills", "apps",
		"tenant_composer_defaults", "tenant_app_defaults":
		l.service.InvalidateAll()
		l.logger.Info(ctx, "composer listener: cache cleared", "trigger", payload)
	case "agent_capability_bindings", "digital_employees":
		id, err := strconv.ParseInt(idStr, 10, 64)
		if err != nil || id <= 0 {
			return
		}
		l.service.InvalidateAgentCache(id)
		l.logger.Info(ctx, "composer listener: agent cache invalidated",
			"trigger", payload, "de_id", id)
	default:
		// 其它前缀: emp_block_registry / contact_policy / auth_revoke / ... 与本服务无关.
	}
}
