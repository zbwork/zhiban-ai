// cmd/audit-writer
//
// v1: 消费 PG events_outbox 表 → 写 audit_events 普通表（详见 ADR 0002 + docs/tasks/m0-cross-cutting-infra.md T0.6）。
//
// 未来（ADR 0002 升级条件触发后）：改为消费 Kafka topic + 写 ClickHouse。
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/config"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/pgcli"
	auditrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/audit"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/auditwriter"
)

func main() {
	cfgPath := flag.String("config", "configs/community/admin.yaml", "config file")
	flag.Parse()

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	logger := logpkg.New("json", "info", "", "community-audit")

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	pool, err := pgcli.New(ctx, cfg.PostgresDSN, 5, 0)
	if err != nil {
		log.Fatalf("pg pool: %v", err)
	}
	defer pool.Close()

	auditStore := auditrepo.New(pool)
	loop := auditwriter.New(pool, auditStore, auditwriter.Config{BatchSize: 100, PollMS: 1000, BackoffMaxMS: 60000, MaxAttempts: 5}, logger)

	logger.Info(ctx, "audit-writer starting",
		"pg_max_conns", 5)

	// Run 阻塞直到 ctx 取消。
	if err := loop.Run(ctx); err != nil {
		log.Fatalf("loop run: %v", err)
	}

	logger.Info(context.Background(), "audit-writer stopped")
	_ = os.Stdout.Sync()
}
