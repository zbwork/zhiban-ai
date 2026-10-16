package contacts

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

// PolicyListener 监听 PG NOTIFY config_change, 失效 contacts 服务里的本地缓存 (M2 §8)。
//
// 仅处理 payload="contact_policies:<tid>"; 其它前缀
// (membership:* / digital_employees:* / agent_visibility:*) 当前不缓存,
// 收到也只记日志, 留作未来扩展。
//
// 启动: go listener.Run(ctx)。失败 1s backoff 自动重连, 与 service/auth/pglistener 风格一致。
type PolicyListener struct {
	pool   *pgxpool.Pool
	svc    *impl
	logger *logpkg.Logger
}

// NewPolicyListener 构造。svc 必须是 contacts.New 返回的 *impl。
//
// 由于 Service 是接口, 这里通过类型断言反向拿到 *impl;
// 不暴露 InvalidatePolicy 在接口上, 避免业务代码误调。
func NewPolicyListener(pool *pgxpool.Pool, svc Service, logger *logpkg.Logger) *PolicyListener {
	i, _ := svc.(*impl)
	return &PolicyListener{pool: pool, svc: i, logger: logger}
}

// Run 阻塞监听 config_change。ctx 取消时退出。
func (l *PolicyListener) Run(ctx context.Context) {
	if l.svc == nil {
		// 没有 *impl 句柄就不需要监听了
		return
	}
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		if err := l.loop(ctx); err != nil {
			l.logger.Warn(ctx, "pglisten.config_change.loop_err", "err", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Second):
			}
		}
	}
}

func (l *PolicyListener) loop(ctx context.Context) error {
	conn, err := l.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "LISTEN config_change"); err != nil {
		return err
	}
	l.logger.Info(ctx, "pglisten.config_change.listening")
	for {
		notif, err := conn.Conn().WaitForNotification(ctx)
		if err != nil {
			return err
		}
		l.handle(ctx, notif.Payload)
	}
}

// handle 解析 payload 并触发对应失效。
//
// 已识别 payload:
//
//	contact_policies:<tid>           失效该租户 policy 缓存
//	contact_policies:                兜底, 失效所有 policy 缓存
//
// 其它前缀本期仅记日志。
func (l *PolicyListener) handle(ctx context.Context, payload string) {
	parts := strings.SplitN(payload, ":", 2)
	if len(parts) == 0 {
		return
	}
	switch parts[0] {
	case "contact_policies":
		var tid int64
		if len(parts) == 2 {
			tid, _ = strconv.ParseInt(parts[1], 10, 64)
		}
		l.svc.InvalidatePolicy(tid)
		l.logger.Info(ctx, "pglisten.config_change.policy_invalidated", "tid", tid)
	case "membership", "digital_employees", "agent_visibility":
		l.logger.Info(ctx, "pglisten.config_change.observed", "payload", payload)
	default:
		l.logger.Info(ctx, "pglisten.config_change.unknown", "payload", payload)
	}
}
