// purge.go — F03 v0.9.1 §11 cron worker：清理过期数据。
//
// 两类清理（每隔 1h 跑一次，跨实例靠 PG advisory lock 互斥）：
//   - user_agent_skill_overrides: expires_at < now() 的 hard delete
//   - client_builtin_handshakes: last_reported_at < now() - BuiltinHandshakeTTL
package skill

import (
	"context"
	"time"

	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

// PurgeWorker 简单 ticker；多副本同时跑也安全（DELETE 幂等）。
type PurgeWorker struct {
	repo     domskill.Repository
	logger   *log.Logger
	cfg      Config
	interval time.Duration
}

func NewPurgeWorker(repo domskill.Repository, logger *log.Logger, cfg Config) *PurgeWorker {
	if logger == nil {
		logger = log.Default()
	}
	return &PurgeWorker{repo: repo, logger: logger, cfg: cfg, interval: time.Hour}
}

func (w *PurgeWorker) Run(ctx context.Context) {
	if err := w.tick(ctx); err != nil && ctx.Err() == nil {
		w.logger.Warn(ctx, "skill purge: first tick err", "err", err)
	}
	t := time.NewTicker(w.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := w.tick(ctx); err != nil && ctx.Err() == nil {
				w.logger.Warn(ctx, "skill purge: tick err", "err", err)
			}
		}
	}
}

func (w *PurgeWorker) tick(ctx context.Context) error {
	n1, err := w.repo.PurgeExpiredUserOverrides(ctx)
	if err != nil {
		return err
	}
	cutoff := time.Now().Add(-w.cfg.BuiltinHandshakeTTL)
	n2, err := w.repo.PurgeStaleHandshakes(ctx, cutoff)
	if err != nil {
		return err
	}
	if n1 > 0 || n2 > 0 {
		w.logger.Info(ctx, "skill purge: removed",
			"user_overrides", n1, "stale_handshakes", n2)
	}
	if err := w.repo.RecomputeInstallCounts(ctx); err != nil {
		return err
	}
	return nil
}
