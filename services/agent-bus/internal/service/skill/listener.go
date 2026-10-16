// listener.go — F03 v0.9.1 SkillHub PG NOTIFY 监听器（spec §4.6 / §9）。
//
// 复用 composer.ConfigChangeChannel = "config_change"，按 payload 前缀分发：
//   - skills:<id>                                          → broadcast 跨 agent 影响
//   - agent_skill_bindings:<agent_id>                      → 单 agent 影响
//   - tenant_skill_preferences:<tenant_id>                 → 单 tenant 影响
//   - tenant_skill_disables:<tenant_id>                    → 单 tenant 影响
//   - user_agent_skill_overrides:<account_id>:<agent_id>   → 单 (user, agent)
//   - builtin_skill_keys:<id>                              → 全局
//
// **当前 slice 仅记日志 + 调用 Invalidator 钩子**：
//   - SkillHub 还没有进程内 chip rail cache（每次拉接口实时组装）
//   - 但暴露 Invalidator hook，允许 cmd/bus 注入：
//     (1) 走 SSE 推 chip-rail-config-invalidate 事件给客户端（spec §3.3.A）
//     (2) 后续接 LRU cache 时直接挂上
//
// 与 composer.Listener 各自独立 LISTEN session（一个 conn 只 LISTEN 一个 channel
// 也无所谓，pgx 同一 channel 多个 conn 都收）— 不冲突。
package skill

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	svccomposer "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/composer"
)

// Invalidator 接收 listener 解析出的失效信号；nil 时 listener 仅记日志。
type Invalidator interface {
	// InvalidateSkill: skill 元 / 版本 publish/archive/rollback 时全局影响。
	InvalidateSkill(skillID int64)
	// InvalidateAgent: agent 装配变更。
	InvalidateAgent(agentID int64)
	// InvalidateTenant: 租户偏好 / 禁用变更。
	InvalidateTenant(tenantID int64)
	// InvalidateUserAgent: 单用户 × 单 agent 临时 override 变更。
	InvalidateUserAgent(accountID, agentID int64)
	// InvalidateAll: builtin_skill_keys 等全局。
	InvalidateAll()
}

// Listener 阻塞监听 config_change 通道，分发 SkillHub 事件。
type Listener struct {
	pool        *pgxpool.Pool
	logger      *log.Logger
	invalidator Invalidator
}

// NewListener 构造；invalidator 可 nil（仅日志模式）。
func NewListener(pool *pgxpool.Pool, logger *log.Logger, inv Invalidator) *Listener {
	if logger == nil {
		logger = log.Default()
	}
	return &Listener{pool: pool, logger: logger, invalidator: inv}
}

// Run 阻塞监听；ctx 取消即退出。cmd/bus 在 bgWG 里跑。
func (l *Listener) Run(ctx context.Context) {
	for {
		if err := l.runOnce(ctx); err != nil {
			if ctx.Err() != nil {
				return
			}
			l.logger.Warn(ctx, "skill listener: loop err; retry in 1s", "err", err)
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
	if _, err := conn.Exec(ctx, "LISTEN "+svccomposer.ConfigChangeChannel); err != nil {
		return err
	}
	l.logger.Info(ctx, "skill listener: listening "+svccomposer.ConfigChangeChannel)
	for {
		notif, err := conn.Conn().WaitForNotification(ctx)
		if err != nil {
			return err
		}
		l.handle(ctx, notif.Payload)
	}
}

func (l *Listener) handle(ctx context.Context, payload string) {
	switch {
	case strings.HasPrefix(payload, "skills:"):
		id, ok := parseInt(strings.TrimPrefix(payload, "skills:"))
		if !ok {
			return
		}
		if l.invalidator != nil {
			l.invalidator.InvalidateSkill(id)
		}
		l.logger.Info(ctx, "skill listener: skill changed", "skill_id", id)
	case strings.HasPrefix(payload, "agent_skill_bindings:"):
		id, ok := parseInt(strings.TrimPrefix(payload, "agent_skill_bindings:"))
		if !ok {
			return
		}
		if l.invalidator != nil {
			l.invalidator.InvalidateAgent(id)
		}
		l.logger.Info(ctx, "skill listener: agent bindings changed", "agent_id", id)
	case strings.HasPrefix(payload, "tenant_skill_preferences:"):
		id, ok := parseInt(strings.TrimPrefix(payload, "tenant_skill_preferences:"))
		if !ok {
			return
		}
		if l.invalidator != nil {
			l.invalidator.InvalidateTenant(id)
		}
		l.logger.Info(ctx, "skill listener: tenant prefs changed", "tenant_id", id)
	case strings.HasPrefix(payload, "tenant_skill_disables:"):
		id, ok := parseInt(strings.TrimPrefix(payload, "tenant_skill_disables:"))
		if !ok {
			return
		}
		if l.invalidator != nil {
			l.invalidator.InvalidateTenant(id)
		}
		l.logger.Info(ctx, "skill listener: tenant disables changed", "tenant_id", id)
	case strings.HasPrefix(payload, "user_agent_skill_overrides:"):
		rest := strings.TrimPrefix(payload, "user_agent_skill_overrides:")
		parts := strings.SplitN(rest, ":", 2)
		if len(parts) != 2 {
			return
		}
		aid, ok1 := parseInt(parts[0])
		agid, ok2 := parseInt(parts[1])
		if !ok1 || !ok2 {
			return
		}
		if l.invalidator != nil {
			l.invalidator.InvalidateUserAgent(aid, agid)
		}
		l.logger.Info(ctx, "skill listener: user override changed",
			"account_id", aid, "agent_id", agid)
	case strings.HasPrefix(payload, "builtin_skill_keys"):
		if l.invalidator != nil {
			l.invalidator.InvalidateAll()
		}
		l.logger.Info(ctx, "skill listener: builtin keys changed")
	default:
		// 其它前缀（composer / contacts / emp_block 等）由各自 listener 处理。
	}
}

func parseInt(s string) (int64, bool) {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v <= 0 {
		return 0, false
	}
	return v, true
}
